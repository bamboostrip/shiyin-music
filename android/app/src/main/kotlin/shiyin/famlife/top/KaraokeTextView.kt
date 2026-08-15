package shiyin.famlife.top

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.SystemClock
import android.util.AttributeSet
import android.util.TypedValue
import android.view.Choreographer
import android.view.View
import kotlin.math.abs

/**
 * Custom view that renders lyrics with a karaoke-style horizontal fill effect.
 * The text is drawn in a dim base color, then an active portion is drawn in a
 * bright color, clipped to the current progress width.
 *
 * 长行歌词处理：当歌词宽度超过可用宽度时启用跑马灯横向滚动（整行向左滚到
 * 末尾完全可见，停留片刻后回到起点循环），保证长行完整可见；短行歌词不
 * 滚动、不占用任何帧回调，行为与之前完全一致。卡拉 OK 高亮裁剪随文本一起
 * 平移，进度填充关系不变。
 */
class KaraokeTextView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val basePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.LEFT
        isFakeBoldText = true
    }

    private val activePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.LEFT
        isFakeBoldText = true
    }

    private val clipRect = RectF()
    private val choreographer = Choreographer.getInstance()

    // ---- 跑马灯参数（仅在文本溢出可用宽度时生效，短行无任何开销）----
    private val marqueeSpeedPxPerMs = 0.06f // 滚动速度 60px/s，车机低性能设备友好
    private val marqueeStartHoldMs = 600L // 起点停留
    private val marqueeEndHoldMs = 1200L // 末尾全文可见停留

    private enum class MarqueePhase { HOLD_START, SCROLL, HOLD_END }

    private var scrollOffset = 0f
    private var marqueePhase = MarqueePhase.HOLD_START
    private var marqueePhaseStartMs = 0L
    private var marqueeFrameCallback: Choreographer.FrameCallback? = null

    var text: String = ""
        set(value) {
            if (field != value) {
                field = value
                restartMarquee()
                requestLayout()
                invalidate()
            }
        }

    var baseColor: Int = Color.argb(90, 255, 255, 255)
        set(value) {
            field = value
            basePaint.color = value
            invalidate()
        }

    var activeColor: Int = Color.WHITE
        set(value) {
            field = value
            activePaint.color = value
            invalidate()
        }

    var textSizeSp: Float = 16f
        set(value) {
            field = value
            val px = TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics
            )
            basePaint.textSize = px
            activePaint.textSize = px
            requestLayout()
            invalidate()
        }

    /** Progress from 0.0 (nothing highlighted) to 1.0 (fully highlighted). */
    var progress: Float = 0f
        set(value) {
            val clamped = value.coerceIn(0f, 1f)
            if (abs(field - clamped) > 0.001f) {
                field = clamped
                invalidate()
            }
        }

    // 长行走单行跑马灯，行高固定为一行（原 maxLines=2 只有高度生效，并无换行绘制）
    var maxLines: Int = 1

    init {
        val px = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP, textSizeSp, resources.displayMetrics
        )
        basePaint.textSize = px
        activePaint.textSize = px
        basePaint.color = baseColor
        activePaint.color = activeColor
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val widthMode = MeasureSpec.getMode(widthMeasureSpec)
        val widthSize = MeasureSpec.getSize(widthMeasureSpec)

        val width = when (widthMode) {
            MeasureSpec.EXACTLY -> widthSize
            MeasureSpec.AT_MOST -> {
                val textWidth = if (text.isEmpty()) 0f
                else basePaint.measureText(text).coerceAtMost(widthSize.toFloat())
                (textWidth + paddingLeft + paddingRight).toInt().coerceAtMost(widthSize)
            }
            else -> {
                val textWidth = if (text.isEmpty()) 0f else basePaint.measureText(text)
                (textWidth + paddingLeft + paddingRight).toInt()
            }
        }

        val lineHeight = basePaint.fontMetrics.let { it.bottom - it.top + it.leading }
        val textHeight = (lineHeight * maxLines.coerceAtLeast(1))
        val height = (textHeight + paddingTop + paddingBottom).toInt()

        setMeasuredDimension(width, height)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // 宽度变化（字体大小调整、悬浮窗重排等）后重新评估是否需要滚动
        ensureMarquee()
    }

    override fun onDetachedFromWindow() {
        // 悬浮窗关闭时停止帧回调，避免泄漏
        stopMarquee()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (text.isEmpty()) return

        // 长行滚动时整行左移；短行 scrollOffset 恒为 0，绘制与之前一致
        val x = paddingLeft.toFloat() - scrollOffset
        val y = paddingTop - basePaint.fontMetrics.top

        // Draw base (dim) text
        canvas.drawText(text, x, y, basePaint)

        // Draw active (bright) text clipped to progress
        if (progress > 0f) {
            val totalWidth = basePaint.measureText(text)
            val clipWidth = totalWidth * progress
            clipRect.set(
                x,
                0f,
                x + clipWidth,
                height.toFloat()
            )
            canvas.save()
            canvas.clipRect(clipRect)
            canvas.drawText(text, x, y, activePaint)
            canvas.restore()
        }
    }

    /** 歌词文本变化后重置滚动，等布局稳定后再评估是否启动。 */
    private fun restartMarquee() {
        stopMarquee()
        post { ensureMarquee() }
    }

    /** 文本溢出可用宽度时启动滚动动画，否则停止并复位。 */
    private fun ensureMarquee() {
        if (!isAttachedToWindow) return
        val textWidth = basePaint.measureText(text)
        val contentWidth = (width - paddingLeft - paddingRight).toFloat()
        if (textWidth > contentWidth && marqueeFrameCallback == null) {
            scrollOffset = 0f
            marqueePhase = MarqueePhase.HOLD_START
            marqueePhaseStartMs = SystemClock.uptimeMillis()
            val callback = object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    onMarqueeFrame()
                }
            }
            marqueeFrameCallback = callback
            choreographer.postFrameCallback(callback)
        } else if (textWidth <= contentWidth) {
            stopMarquee()
        }
    }

    private fun stopMarquee() {
        marqueeFrameCallback?.let { choreographer.removeFrameCallback(it) }
        marqueeFrameCallback = null
        if (scrollOffset != 0f) {
            scrollOffset = 0f
            invalidate()
        }
    }

    private fun onMarqueeFrame() {
        val callback = marqueeFrameCallback ?: return
        val nowMs = SystemClock.uptimeMillis()
        val maxScroll = (basePaint.measureText(text) -
            (width - paddingLeft - paddingRight)).coerceAtLeast(0f)
        if (maxScroll <= 0f) {
            stopMarquee()
            return
        }
        when (marqueePhase) {
            MarqueePhase.HOLD_START -> {
                if (nowMs - marqueePhaseStartMs >= marqueeStartHoldMs) {
                    marqueePhase = MarqueePhase.SCROLL
                    marqueePhaseStartMs = nowMs
                }
            }
            MarqueePhase.SCROLL -> {
                scrollOffset = ((nowMs - marqueePhaseStartMs) * marqueeSpeedPxPerMs)
                    .coerceAtMost(maxScroll)
                if (scrollOffset >= maxScroll) {
                    marqueePhase = MarqueePhase.HOLD_END
                    marqueePhaseStartMs = nowMs
                }
            }
            MarqueePhase.HOLD_END -> {
                if (nowMs - marqueePhaseStartMs >= marqueeEndHoldMs) {
                    marqueePhase = MarqueePhase.HOLD_START
                    marqueePhaseStartMs = nowMs
                    scrollOffset = 0f
                }
            }
        }
        invalidate()
        choreographer.postFrameCallback(callback)
    }
}
