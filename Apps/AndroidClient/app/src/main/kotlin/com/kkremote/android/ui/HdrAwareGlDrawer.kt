package com.kkremote.android.ui

import android.opengl.GLES11Ext
import android.opengl.GLES20
import org.webrtc.GlShader
import org.webrtc.GlUtil
import org.webrtc.RendererCommon
import java.nio.FloatBuffer

/**
 * Color-managed OpenGL ES drawer implementing WebRTC's public [RendererCommon.GlDrawer]:
 * - SDR (H.264 BT.709/sRGB): zero-overhead passthrough.
 * - HDR (HEVC Main10 ITU-R BT.2020 + SMPTE ST 2084 PQ from macOS ScreenCaptureKit):
 *   applies exact highp ST 2084 PQ EOTF normalized to Apple's 203-nit SDR reference white,
 *   converts linear Rec.2020 primaries to linear Rec.709/sRGB, and encodes IEC 61966-2-1 sRGB
 *   so desktop whites (#FFFFFF) and colors never appear gray or desaturated on TextureView.
 */
class HdrAwareGlDrawer : RendererCommon.GlDrawer {

    private enum class InputKind { OES, RGB, YUV }

    @Volatile
    private var hdrPqEnabled: Boolean = false

    private var currentKind: InputKind? = null
    private var currentShader: GlShader? = null
    private var inPosLocation: Int = -1
    private var inTcLocation: Int = -1
    private var texMatrixLocation: Int = -1
    private var hdrFlagLocation: Int = -1

    fun setHdrPqEnabled(enabled: Boolean) {
        hdrPqEnabled = enabled
    }

    override fun drawOes(
        oesTextureId: Int,
        texMatrix: FloatArray,
        frameWidth: Int,
        frameHeight: Int,
        viewportX: Int,
        viewportY: Int,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        prepareShader(InputKind.OES, texMatrix)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    override fun drawRgb(
        textureId: Int,
        texMatrix: FloatArray,
        frameWidth: Int,
        frameHeight: Int,
        viewportX: Int,
        viewportY: Int,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        prepareShader(InputKind.RGB, texMatrix)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textureId)
        GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    override fun drawYuv(
        yuvTextures: IntArray,
        texMatrix: FloatArray,
        frameWidth: Int,
        frameHeight: Int,
        viewportX: Int,
        viewportY: Int,
        viewportWidth: Int,
        viewportHeight: Int,
    ) {
        prepareShader(InputKind.YUV, texMatrix)
        for (i in 0 until 3) {
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + i)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, yuvTextures[i])
        }
        GLES20.glViewport(viewportX, viewportY, viewportWidth, viewportHeight)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        for (i in 0 until 3) {
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + i)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        }
    }

    private fun prepareShader(kind: InputKind, texMatrix: FloatArray) {
        val shader: GlShader
        if (kind == currentKind && currentShader != null) {
            shader = currentShader!!
        } else {
            currentShader?.release()
            val created = GlShader(VERTEX_SHADER, buildFragmentShader(kind))
            currentKind = kind
            currentShader = created
            created.useProgram()
            when (kind) {
                InputKind.OES -> GLES20.glUniform1i(created.getUniformLocation("oes_tex"), 0)
                InputKind.RGB -> GLES20.glUniform1i(created.getUniformLocation("rgb_tex"), 0)
                InputKind.YUV -> {
                    GLES20.glUniform1i(created.getUniformLocation("y_tex"), 0)
                    GLES20.glUniform1i(created.getUniformLocation("u_tex"), 1)
                    GLES20.glUniform1i(created.getUniformLocation("v_tex"), 2)
                }
            }
            inPosLocation = created.getAttribLocation("in_pos")
            inTcLocation = created.getAttribLocation("in_tc")
            texMatrixLocation = created.getUniformLocation("tex_mat")
            hdrFlagLocation = created.getUniformLocation("u_isHdrPq")
            GlUtil.checkNoGLES2Error("Initialize HdrAwareGlDrawer shader")
            shader = created
        }

        shader.useProgram()
        GLES20.glEnableVertexAttribArray(inPosLocation)
        GLES20.glVertexAttribPointer(inPosLocation, 2, GLES20.GL_FLOAT, false, 0, FULL_RECT_POS)
        GLES20.glEnableVertexAttribArray(inTcLocation)
        GLES20.glVertexAttribPointer(inTcLocation, 2, GLES20.GL_FLOAT, false, 0, FULL_RECT_TC)
        GLES20.glUniformMatrix4fv(texMatrixLocation, 1, false, texMatrix, 0)
        if (hdrFlagLocation >= 0) {
            GLES20.glUniform1f(hdrFlagLocation, if (hdrPqEnabled) 1.0f else 0.0f)
        }
        GlUtil.checkNoGLES2Error("Prepare HdrAwareGlDrawer")
    }

    override fun release() {
        currentShader?.release()
        currentShader = null
        currentKind = null
    }

    companion object {
        private val FULL_RECT_POS: FloatBuffer = GlUtil.createFloatBuffer(
            floatArrayOf(-1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f)
        )
        private val FULL_RECT_TC: FloatBuffer = GlUtil.createFloatBuffer(
            floatArrayOf(0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f)
        )

        private const val VERTEX_SHADER = """
varying vec2 tc;
attribute vec4 in_pos;
attribute vec4 in_tc;
uniform mat4 tex_mat;
void main() {
  gl_Position = in_pos;
  tc = (tex_mat * in_tc).xy;
}
"""

        private fun buildFragmentShader(kind: InputKind): String = buildString {
            if (kind == InputKind.OES) {
                append("#extension GL_OES_EGL_image_external : require\n")
            }
            append("precision highp float;\n")
            append("varying vec2 tc;\n")
            when (kind) {
                InputKind.OES -> {
                    append("uniform samplerExternalOES oes_tex;\n")
                    append("vec4 sampleFrame(vec2 p) { return texture2D(oes_tex, p); }\n")
                }
                InputKind.RGB -> {
                    append("uniform sampler2D rgb_tex;\n")
                    append("vec4 sampleFrame(vec2 p) { return texture2D(rgb_tex, p); }\n")
                }
                InputKind.YUV -> {
                    append("uniform sampler2D y_tex;\n")
                    append("uniform sampler2D u_tex;\n")
                    append("uniform sampler2D v_tex;\n")
                    append(
                        """
vec4 sampleFrame(vec2 p) {
  float y = texture2D(y_tex, p).r * 1.16438;
  float u = texture2D(u_tex, p).r;
  float v = texture2D(v_tex, p).r;
  return vec4(
    y + 1.59603 * v - 0.874202,
    y - 0.391762 * u - 0.812968 * v + 0.531668,
    y + 2.01723 * u - 1.08563,
    1.0
  );
}
"""
                    )
                }
            }
            append(
                """
uniform float u_isHdrPq;

vec3 pqToLinear203(vec3 e) {
  vec3 c = clamp(e, 0.0, 1.0);
  vec3 ep = pow(c, vec3(0.0126833135));
  vec3 num = max(ep - vec3(0.8359375), vec3(0.0));
  vec3 den = max(vec3(18.8515625) - vec3(18.6875) * ep, vec3(1e-6));
  return pow(num / den, vec3(6.277394636)) * 49.2610837;
}

vec3 linearToSrgb(vec3 lin) {
  vec3 x = clamp(lin, 0.0, 1.0);
  vec3 lo = x * 12.92;
  vec3 hi = 1.055 * pow(max(x, vec3(0.0031308)), vec3(0.416666667)) - 0.055;
  vec3 mask = step(vec3(0.0031308), x);
  return lo * (vec3(1.0) - mask) + hi * mask;
}

void main() {
  vec4 src = sampleFrame(tc);
  if (u_isHdrPq < 0.5) {
    gl_FragColor = src;
    return;
  }
  vec3 lin2020 = pqToLinear203(src.rgb);
  vec3 lin709 = vec3(
     1.660491 * lin2020.r - 0.587641 * lin2020.g - 0.072850 * lin2020.b,
    -0.124550 * lin2020.r + 1.132900 * lin2020.g - 0.008349 * lin2020.b,
    -0.018151 * lin2020.r - 0.100579 * lin2020.g + 1.118730 * lin2020.b
  );
  gl_FragColor = vec4(linearToSrgb(lin709), src.a);
}
"""
            )
        }
    }
}
