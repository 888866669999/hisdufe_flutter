#include <flutter/runtime_effect.glsl>

// 顶部渐变模糊用的「alpha 渐变压暗」着色器。
//
// ===== 它在整条链路里的位置 =====
// 与 ImageFilter.blur 组合使用：
//   ImageFilter.compose(outer: shader(本文件), inner: blur(...))
// 引擎先做真正的高斯模糊（由 ImageFilter.blur 完成，是高度优化的可分离卷积），
// 再把模糊结果作为输入纹理喂进本着色器；本着色器只做一件事 ——
// 按纵向位置压暗 alpha。
//
// 于是模糊层与下层未模糊内容之间形成**连续渐变**的交叉淡入，
// 也就是 iOS 那种「越靠上越糊」的效果。
//
// ===== 为什么不自己在着色器里做多次采样模糊 =====
// 公开的 progressive blur 方案（如 progressive_blur 包）是在着色器里
// 做多抽头采样。那样虽然只用一个 shader，但模糊质量与性能都远不如
// 引擎内置的 ImageFilter.blur，而且 sigma 大时抽头数要跟着涨。
// 这里让 blur 干它最擅长的事，着色器只负责渐变 —— 一次全屏 pass，零分带。
//
// ===== 引擎的绑定约定（来自 Flutter 官方文档，必须遵守）=====
//   * 第一个 uniform 必须是 vec2 —— 引擎会把**纹理尺寸**写进去；
//   * 必须至少有一个 sampler2D —— 引擎会把**滤镜输入**绑到第一个上；
//   * uniform 的名字随意，但顺序不能变。
// 因此 u_size 必须是第一个声明的 uniform，u_texture_input 必须是最先声明的 sampler。

uniform vec2 u_size;          // ← 引擎写入：纹理尺寸
uniform float u_keep;         // ← 我们设置：满强度区的结束位置（归一化 0..1）
uniform float u_fade;         // ← 我们设置：衰减到 0 的位置（归一化 0..1）
uniform sampler2D u_texture_input;  // ← 引擎绑定：模糊后的画面

out vec4 frag_color;

void main() {
  vec2 uv = FlutterFragCoord().xy / u_size;

  // Impeller 走 OpenGL(ES) 后端时 y 轴是反的，不翻转会上下颠倒。
  // 官方文档明确要求加这个宏判断。
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  vec4 c = texture(u_texture_input, uv);

  // 纵向渐变：uv.y < u_keep 保持满不透明；到 u_fade 处降到 0。
  //
  // 曲线用标准 smoothstep：两端斜率为 0，因此
  //   - 顶端与满强度区衔接平滑（不会出现「这里突然开始变淡」）；
  //   - 底端与下方清晰内容衔接平滑（不会出现一条可见的糊/清分界）。
  //
  // 用线性插值是不行的：线性在两端有非零斜率，过渡起止都会留下
  // 一道可辨认的边（这也是分带方案段落感的来源之一）。
  float span = max(u_fade - u_keep, 1e-4);
  float t = clamp((uv.y - u_keep) / span, 0.0, 1.0);
  float a = 1.0 - t * t * (3.0 - 2.0 * t);

  frag_color = vec4(c.rgb, c.a * a);
}
