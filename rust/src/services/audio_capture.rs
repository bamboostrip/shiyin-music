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
        total_samples: usize,
        /// 自上次快照以来的峰值振幅(快照时在调用线程输出诊断后复位)。
        /// 音频线程里绝不做 console I/O:println 持有 stdout 锁且是同步写,
        /// 放在实时回调里会拉高回调延迟、并与 snapshot 抢同一把 ring 锁。
        interval_peak: f32,
    }

    impl Ring {
        fn push_interleaved(&mut self, data: &[f32]) {
            let ch = self.channels.max(1) as usize;
            for frame in data.chunks_exact(ch) {
                let sum: f32 = frame.iter().sum();
                let mono = sum / ch as f32;
                self.interval_peak = self.interval_peak.max(mono.abs());
                self.samples.push(mono);
            }
            self.total_samples += data.len() / ch;
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

        fn tail(&mut self, duration_ms: u32) -> Vec<f32> {
            let n = ((self.sample_rate as u64 * duration_ms as u64) / 1000) as usize;
            let avail = self.samples.len() - self.start;
            let take = n.min(avail);
            let tail = self.samples[self.samples.len() - take..].to_vec();
            self.interval_peak = 0.0;
            tail
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
            total_samples: 0,
            interval_peak: 0.0,
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
                    println!("[AudioCapture] 已选定 Windows 系统输出回环设备: {device}, 混音配置: {config:?}");
                    Ok((device, config, "system"))
                }
                #[cfg(target_os = "linux")]
                {
                    for device in host
                        .input_devices()
                        .map_err(|e| format!("枚举输入设备失败: {e}"))?
                    {
                        let name = format!("{device}").to_ascii_lowercase();
                        if name.contains("monitor")
                            || name.contains("loopback")
                            || name.contains("stereo mix")
                        {
                            let config = device
                                .default_input_config()
                                .map_err(|e| format!("读取回环设备配置失败: {e}"))?;
                            println!("[AudioCapture] 已选定 Linux 监视器设备: {device}");
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
                println!("[AudioCapture] 已选定麦克风输入设备: {device}, 输入配置: {config:?}");
                Ok((device, config, "mic"))
            }
        }
    }

    /// 开始采集(已在采集中则幂等返回 Ok)。
    pub fn start(source: &str) -> Result<(), String> {
        let mut guard = CAPTURE.lock().map_err(|_| "采集状态锁不可用")?;
        if guard.is_some() {
            println!("[AudioCapture] 采集已处于运行状态，无需重复启动");
            return Ok(());
        }
        println!("[AudioCapture] 开始启动音频采集, source = \"{source}\"");
        let host = cpal::default_host();
        let (device, config, resolved_source) = select_device(&host, source)?;
        // cpal 0.17 起 SampleRate 是 u32 类型别名(不再是 struct),无需取字段。
        let ring = ring_from_config(config.sample_rate(), config.channels());

        let err_fn = move |e| {
            eprintln!("[AudioCapture] 采集流错误: {e}");
            tracing::warn!(error = %e, "识曲采集流错误");
        };
        // cpal 0.18 起 build_*_stream 按值收 StreamConfig(不再收引用)。
        let cfg: cpal::StreamConfig = config.clone().into();
        println!(
            "[AudioCapture] 正在创建采集流: source=\"{resolved_source}\", 采样率={}Hz, 声道数={}, 格式={:?}",
            config.sample_rate(),
            config.channels(),
            config.sample_format()
        );
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
        println!("[AudioCapture] 音频采集流启动成功，开始监听...");
        Ok(())
    }

    pub fn stop() {
        if let Ok(mut guard) = CAPTURE.lock() {
            if guard.is_some() {
                println!("[AudioCapture] 停止并释放音频采集流");
                *guard = None; // Stream drop = 停止
            }
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
            println!("[AudioCapture] 提取快照失败: 采集尚未启动");
            return Err("采集未启动".into());
        };
        let (samples, src_rate, total_samples, interval_peak) = {
            let mut r = state.ring.lock().map_err(|_| "环形缓冲锁不可用")?;
            let tail = r.tail(duration_ms);
            (
                tail,
                r.sample_rate,
                r.total_samples,
                std::mem::replace(&mut r.interval_peak, 0.0),
            )
        };
        let peak = samples.iter().copied().fold(0.0f32, |a, b| a.max(b.abs()));
        println!(
            "[AudioCapture] 提取 PCM 快照: 请求时长={}ms, 累计接收采样={}, 快照采样数={} (约{:.2}s), 快照峰值振幅={:.4}, 期间峰值振幅={:.4}",
            duration_ms,
            total_samples,
            samples.len(),
            samples.len() as f32 / src_rate.max(1) as f32,
            peak,
            interval_peak
        );
        if total_samples == 0 || samples.is_empty() {
            println!("[AudioCapture] 警告: 采集缓冲区为空 (0 采样)! 若使用系统内录(system)，请确认系统默认输出设备当前正在播放声音。");
        } else if peak < 0.001 {
            println!("[AudioCapture] 提示: 采集到的声音音量接近全静音 (峰值振幅={:.4})", peak);
        }
        let pcm = mono_f32_to_pcm8k(&samples, src_rate);
        println!(
            "[AudioCapture] PCM 转换完成: 8000Hz/16bit/单声道输出字节数={}",
            pcm.len()
        );
        Ok(pcm)
    }

    /// 单声道 f32(源采样率)→ 8000Hz s16le PCM。
    pub(crate) fn mono_f32_to_pcm8k(samples: &[f32], src_rate: u32) -> Vec<u8> {
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
                total_samples: 0,
                interval_peak: 0.0,
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
            let mut ring = Ring {
                samples: (0..48000).map(|i| i as f32).collect(),
                start: 0,
                sample_rate: 48000,
                channels: 1,
                total_samples: 48000,
                interval_peak: 0.0,
            };
            let tail = ring.tail(500);
            assert_eq!(tail.len(), 24000);
            assert_eq!(tail[0], 24000.0);
        }

        #[test]
        fn test_loopback_stream() {
            use cpal::traits::*;
            let host = cpal::default_host();
            let Some(out) = host.default_output_device() else {
                println!("No output device");
                return;
            };
            println!("Probing loopback on: {out}");
            let config = match out.default_output_config() {
                Ok(c) => c,
                Err(e) => {
                    println!("Failed to get default_output_config: {e}");
                    return;
                }
            };
            println!("Config: {config:?}");
            let cfg: cpal::StreamConfig = config.clone().into();

            // First start an output stream playing a sine wave so WASAPI engine renders audio
            let sample_rate = config.sample_rate() as f32;
            let channels = config.channels() as usize;
            let mut sample_clock = 0f32;
            let out_stream = out.build_output_stream(
                cfg.clone(),
                move |data: &mut [f32], _| {
                    for frame in data.chunks_mut(channels) {
                        let value = (sample_clock * 440.0 * 2.0 * std::f32::consts::PI / sample_rate).sin() * 0.3;
                        sample_clock = (sample_clock + 1.0) % sample_rate;
                        for sample in frame.iter_mut() {
                            *sample = value;
                        }
                    }
                },
                |e| println!("Output stream error: {e}"),
                None,
            ).expect("build output stream");
            out_stream.play().expect("play output stream");

            // Give the render stream a moment to start
            std::thread::sleep(std::time::Duration::from_millis(50));

            let count = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let max_amp = std::sync::Arc::new(std::sync::Mutex::new(0.0f32));
            let count_clone = count.clone();
            let max_amp_clone = max_amp.clone();
            let in_stream = out.build_input_stream(
                cfg,
                move |data: &[f32], _| {
                    let c = count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let mut local_max = 0.0f32;
                    for &s in data {
                        local_max = local_max.max(s.abs());
                    }
                    if let Ok(mut g) = max_amp_clone.lock() {
                        *g = g.max(local_max);
                    }
                    if c < 5 {
                        println!("Loopback frame #{c}: samples={}, max_amp={local_max}", data.len());
                    }
                },
                |e| println!("Loopback stream error: {e}"),
                None,
            ).expect("build loopback input stream");

            in_stream.play().expect("play loopback stream");
            std::thread::sleep(std::time::Duration::from_millis(500));
            let total = count.load(std::sync::atomic::Ordering::Relaxed);
            let peak = *max_amp.lock().unwrap();
            println!("When audio is playing: total frames in 500ms = {total}, peak amplitude = {peak}");
            assert!(total > 0, "Expected loopback frames when audio is rendering!");
            assert!(peak > 0.01, "Expected non-silent audio in loopback!");
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
