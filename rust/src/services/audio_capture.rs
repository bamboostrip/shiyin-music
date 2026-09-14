//! 桌面端听歌识曲音频采集(Windows / Linux / macOS)。
//!
//! - mic:cpal 默认输入设备;
//! - system:Windows 对默认输出设备开 input stream(WASAPI loopback,
//!   cpal 0.17+ 支持);Linux 找 PulseAudio/PipeWire 的 monitor 源;
//!   其余平台返回错误;
//! - 采集回调里下混为单声道 f32 进环形缓冲(约 20s),快照时取末尾
//!   N 秒重采样到 8000Hz 转 s16le——酷狗识曲的 PCM 格式。
//!
//! 线程模型:cpal 回调跑在音频线程,只做"下混 + 环形缓冲追加";
//! 快照/停止在调用线程,锁粒度小,与响度分析的 AtomicBool 取消模式
//! 同级简单。cpal `Stream` drop 即停,无需显式 close。

/// 平台分发:桌面走 desktop 模块,其余走 stub。
pub fn start_with(source: &str) -> Result<(), String> {
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        desktop::start(source)
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        let _ = source;
        stub::start(source)
    }
}

pub fn snapshot_with(duration_ms: u32) -> Result<Vec<u8>, String> {
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        desktop::snapshot_pcm(duration_ms)
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        let _ = duration_ms;
        stub::snapshot_pcm(duration_ms)
    }
}

pub fn stop_with() {
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        desktop::stop()
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        stub::stop()
    }
}

/// 非桌面平台没有采集后端,提供一致的错误桩,保持 api.rs 签名统一。
#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
pub mod stub {
    pub fn start(_source: &str) -> Result<(), String> {
        Err("当前平台不支持音频采集".into())
    }
    pub fn snapshot_pcm(_duration_ms: u32) -> Result<Vec<u8>, String> {
        Err("当前平台不支持音频采集".into())
    }
    pub fn stop() {}
}

#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
pub mod desktop {
    use std::sync::{Arc, Mutex};

    // cpal 0.18 的设备/主机/流方法都在 trait 里,必须显式引入作用域。
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    /// 环形缓冲上限(秒)。识曲快照最多取 10s,留一倍余量防抖。
    const RING_SECS: usize = 20;
    /// 识曲 PCM 目标采样率(酷狗指纹服务固定 8000Hz/16bit/单声道)。
    pub const TARGET_RATE: u32 = 8000;

    struct Ring {
        /// 单声道 f32,设备采样率
        samples: Vec<f32>,
        /// 有效起点(samples 尾裁后整体前移,惰性 drain)
        start: usize,
        sample_rate: u32,
        channels: u16,
    }

    impl Ring {
        fn push_interleaved(&mut self, data: &[f32]) {
            let ch = self.channels.max(1) as usize;
            for frame in data.chunks_exact(ch) {
                let sum: f32 = frame.iter().sum();
                self.samples.push(sum / ch as f32);
            }
            let cap = RING_SECS * self.sample_rate as usize;
            let len = self.samples.len() - self.start;
            if len > cap {
                self.start = self.samples.len() - cap;
                // 起点过半时整体前移,防 Vec 无界增长
                if self.start > cap / 2 {
                    self.samples.drain(..self.start);
                    self.start = 0;
                }
            }
        }

        fn tail(&self, duration_ms: u32) -> Vec<f32> {
            let n = ((self.sample_rate as u64 * duration_ms as u64) / 1000) as usize;
            let avail = self.samples.len() - self.start;
            let take = n.min(avail);
            self.samples[self.samples.len() - take..].to_vec()
        }
    }

    struct CaptureState {
        ring: Arc<Mutex<Ring>>,
        /// 保活即采集,drop 即停止
        _stream: cpal::Stream,
    }

    static CAPTURE: Mutex<Option<CaptureState>> = Mutex::new(None);

    fn ring_from_config(sample_rate: u32, channels: u16) -> Arc<Mutex<Ring>> {
        Arc::new(Mutex::new(Ring {
            samples: Vec::new(),
            start: 0,
            sample_rate,
            channels,
        }))
    }

    fn push_mono(ring: &Arc<Mutex<Ring>>, data: &[f32]) {
        if let Ok(mut r) = ring.lock() {
            r.push_interleaved(data);
        }
    }

    /// 选设备:mic = 默认输入;system = 回环源(Win: 默认输出设备 loopback;
    /// Linux: monitor 名匹配)。
    fn select_device(
        host: &cpal::Host,
        source: &str,
    ) -> Result<(cpal::Device, cpal::SupportedStreamConfig, &'static str), String> {
        match source {
            "system" => {
                #[cfg(target_os = "windows")]
                {
                    let device = host
                        .default_output_device()
                        .ok_or("未找到默认输出设备,无法系统内录")?;
                    let config = device
                        .default_output_config()
                        .map_err(|e| format!("读取输出混音格式失败: {e}"))?;
                    Ok((device, config, "system"))
                }
                #[cfg(target_os = "linux")]
                {
                    for device in host
                        .input_devices()
                        .map_err(|e| format!("枚举输入设备失败: {e}"))?
                    {
                        let name = device.name().unwrap_or_default().to_ascii_lowercase();
                        if name.contains("monitor")
                            || name.contains("loopback")
                            || name.contains("stereo mix")
                        {
                            let config = device
                                .default_input_config()
                                .map_err(|e| format!("读取回环设备配置失败: {e}"))?;
                            return Ok((device, config, "system"));
                        }
                    }
                    Err("未找到系统回环采集源(monitor/loopback),请改用麦克风".into())
                }
                #[cfg(not(any(target_os = "windows", target_os = "linux")))]
                {
                    let _ = host;
                    Err("该平台暂不支持系统内录".into())
                }
            }
            _ => {
                let device = host.default_input_device().ok_or("未找到麦克风设备")?;
                let config = device
                    .default_input_config()
                    .map_err(|e| format!("读取麦克风配置失败: {e}"))?;
                Ok((device, config, "mic"))
            }
        }
    }

    /// 开始采集(已在采集中则幂等返回 Ok)。
    pub fn start(source: &str) -> Result<(), String> {
        let mut guard = CAPTURE.lock().map_err(|_| "采集状态锁不可用")?;
        if guard.is_some() {
            return Ok(());
        }
        let host = cpal::default_host();
        let (device, config, _) = select_device(&host, source)?;
        // cpal 0.17 起 SampleRate 是 u32 类型别名(不再是 struct),无需取字段。
        let ring = ring_from_config(config.sample_rate(), config.channels());

        let err_fn = |e| tracing::warn!(error = %e, "识曲采集流错误");
        // cpal 0.18 起 build_*_stream 按值收 StreamConfig(不再收引用)。
        let cfg: cpal::StreamConfig = config.into();
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                cfg,
                {
                    let ring = ring.clone();
                    move |data: &[f32], _| push_mono(&ring, data)
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                cfg,
                {
                    let ring = ring.clone();
                    move |data: &[i16], _| {
                        let f: Vec<f32> = data.iter().map(|&s| s as f32 / 32768.0).collect();
                        push_mono(&ring, &f);
                    }
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::U16 => device.build_input_stream(
                cfg,
                {
                    let ring = ring.clone();
                    move |data: &[u16], _| {
                        let f: Vec<f32> = data
                            .iter()
                            .map(|&s| (s as f32 - 32768.0) / 32768.0)
                            .collect();
                        push_mono(&ring, &f);
                    }
                },
                err_fn,
                None,
            ),
            fmt => return Err(format!("不支持的采样格式 {fmt:?}")),
        }
        .map_err(|e| format!("打开采集流失败: {e}"))?;
        stream.play().map_err(|e| format!("启动采集流失败: {e}"))?;
        *guard = Some(CaptureState {
            ring,
            _stream: stream,
        });
        Ok(())
    }

    pub fn stop() {
        if let Ok(mut guard) = CAPTURE.lock() {
            *guard = None; // Stream drop = 停止
        }
    }

    /// 查询采集状态(预留:Dart 侧状态展示/防重复启动时经 api.rs 暴露)。
    #[allow(dead_code)]
    pub fn is_capturing() -> bool {
        CAPTURE.lock().map(|g| g.is_some()).unwrap_or(false)
    }

    /// 取末尾 duration_ms 的采集音频,转成 8000Hz/16bit/单声道 PCM。
    pub fn snapshot_pcm(duration_ms: u32) -> Result<Vec<u8>, String> {
        let guard = CAPTURE.lock().map_err(|_| "采集状态锁不可用")?;
        let Some(state) = guard.as_ref() else {
            return Err("采集未启动".into());
        };
        let (samples, src_rate) = {
            let r = state.ring.lock().map_err(|_| "环形缓冲锁不可用")?;
            (r.tail(duration_ms), r.sample_rate)
        };
        Ok(mono_f32_to_pcm8k(&samples, src_rate))
    }

    /// 单声道 f32(源采样率)→ 8000Hz s16le PCM。
    fn mono_f32_to_pcm8k(samples: &[f32], src_rate: u32) -> Vec<u8> {
        let resampled = if src_rate == TARGET_RATE || samples.is_empty() {
            samples.to_vec()
        } else {
            resample_fft(samples, src_rate, TARGET_RATE)
        };
        let mut out = Vec::with_capacity(resampled.len() * 2);
        for s in resampled {
            let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    /// FFT 有理比重采样(rubato),构造/处理异常时回退线性插值——
    /// 识曲指纹对高频混叠不敏感,可用性优先。
    fn resample_fft(samples: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
        use rubato::{FftFixedIn, Resampler};
        let expected =
            (samples.len() as u64 * dst_rate as u64 / src_rate as u64).max(1) as usize;
        let chunk = 8192usize;
        let Ok(mut resampler) = FftFixedIn::<f32>::new(
            src_rate as usize,
            dst_rate as usize,
            chunk,
            4,
            1,
        ) else {
            return resample_linear(samples, src_rate, dst_rate);
        };
        let mut out = Vec::with_capacity(expected);
        let mut pos = 0usize;
        while pos < samples.len() {
            let take = chunk.min(samples.len() - pos);
            let mut frame = vec![vec![0.0f32; chunk]];
            frame[0][..take].copy_from_slice(&samples[pos..pos + take]);
            // rubato 0.16 的 process 带通道掩码参数,单声道传 None。
            match resampler.process(&frame, None) {
                Ok(mut buf) => out.append(&mut buf[0]),
                Err(_) => return resample_linear(samples, src_rate, dst_rate),
            }
            pos += take;
        }
        // rubato 只输出完整内部 FFT 块,末尾不足一块的输入会滞留在内部
        // 缓冲(实测 500ms@48k 少 ~6%)。按官方文档用 process_partial(None)
        // 推出残留帧;零填充导致的尾沿轻微衰减对识曲指纹无感,多出的
        // 输出由 truncate 截到期望长度。
        match resampler.process_partial::<Vec<f32>>(None, None) {
            Ok(mut buf) => out.append(&mut buf[0]),
            Err(_) => return resample_linear(samples, src_rate, dst_rate),
        }
        out.truncate(expected);
        out
    }

    fn resample_linear(samples: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
        let expected =
            (samples.len() as u64 * dst_rate as u64 / src_rate as u64).max(1) as usize;
        let mut out = Vec::with_capacity(expected);
        let step = src_rate as f64 / dst_rate as f64;
        for i in 0..expected {
            let t = i as f64 * step;
            let i0 = (t as usize).min(samples.len() - 1);
            let i1 = (i0 + 1).min(samples.len() - 1);
            let frac = (t - i0 as f64) as f32;
            out.push(samples[i0] + (samples[i1] - samples[i0]) * frac);
        }
        out
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::f32::consts::TAU;

        /// 440Hz 正弦波(振幅 0.5)
        fn sine(freq: f32, rate: u32, ms: u32) -> Vec<f32> {
            let n = (rate as u64 * ms as u64 / 1000) as usize;
            (0..n)
                .map(|i| 0.5 * (TAU * freq * i as f32 / rate as f32).sin())
                .collect()
        }

        fn rms(v: &[f32]) -> f32 {
            (v.iter().map(|x| x * x).sum::<f32>() / v.len().max(1) as f32).sqrt()
        }

        #[test]
        fn pcm8k_silence_length_exact() {
            // 48000Hz 整除比:500ms → 恰好 4000 个 8k 样本 = 8000 字节
            let pcm = mono_f32_to_pcm8k(&vec![0.0; 24000], 48000);
            assert_eq!(pcm.len(), 8000);
            assert!(pcm.iter().all(|&b| b == 0));
        }

        #[test]
        fn pcm8k_tone_keeps_energy_and_ratio() {
            let src = sine(440.0, 48000, 1000);
            let pcm = mono_f32_to_pcm8k(&src, 48000);
            // 1s@8k → 16000 字节(±1% 容忍整除舍入)
            assert!(
                (pcm.len() as i64 - 16000).abs() < 160,
                "len={}",
                pcm.len()
            );
            // s16le 解回 f32,能量应大体保留
            let mut back = Vec::with_capacity(pcm.len() / 2);
            for pair in pcm.chunks_exact(2) {
                back.push(i16::from_le_bytes([pair[0], pair[1]]) as f32 / 32767.0);
            }
            let r = rms(&back);
            assert!(r > 0.25 && r < 0.6, "rms={r}");
        }

        #[test]
        fn pcm8k_odd_ratio_44100() {
            let src = sine(440.0, 44100, 500);
            let pcm = mono_f32_to_pcm8k(&src, 44100);
            let expect = 8000 * 500 / 1000 * 2;
            assert!((pcm.len() as i64 - expect).abs() < 20, "len={}", pcm.len());
        }

        #[test]
        fn ring_downmixes_stereo_and_trims() {
            let mut ring = Ring {
                samples: Vec::new(),
                start: 0,
                sample_rate: 48000,
                channels: 2,
            };
            ring.push_interleaved(&[0.2, 0.6, 0.2, 0.6]);
            // f32 求和不精确,用容差断言
            assert!(ring.samples.len() == 2);
            assert!((ring.samples[0] - 0.4).abs() < 1e-6);
            assert!((ring.samples[1] - 0.4).abs() < 1e-6);
            // 20s 上限裁剪
            ring.push_interleaved(&vec![0.5; 48000 * RING_SECS * 2]);
            assert!(ring.samples.len() <= 48000 * RING_SECS + 2);
        }

        #[test]
        fn ring_tail_takes_last_n_ms() {
            let ring = Ring {
                samples: (0..48000).map(|i| i as f32).collect(),
                start: 0,
                sample_rate: 48000,
                channels: 1,
            };
            let tail = ring.tail(500);
            assert_eq!(tail.len(), 24000);
            assert_eq!(tail[0], 24000.0);
        }
    }
}

#[cfg(test)]
mod tests {
    /// 移动端桩:接口存在且报错(保证 api.rs 全平台可编译)。
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    #[test]
    fn stub_errors() {
        assert!(super::stub::start("mic").is_err());
        assert!(super::stub::snapshot_pcm(1000).is_err());
    }
}
