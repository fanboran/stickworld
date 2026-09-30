#ifndef RL_CORE_MATH_H
#define RL_CORE_MATH_H
// rl_core · 基础数学件（纯 C++，零 Godot 依赖）
//
// RNG 规格（C++ 与 GDScript 镜像两版逐字一致，改一处必改两处）：
//   xorshift32（32 位无符号，避免 64 位乘法溢出导致 GDScript 无法逐位复现）：
//     x ^= x << 13;  x ^= x >> 17;  x ^= x << 5;   （全部按 32 位回绕）
//   seed(0) → 0x9E3779B9 兜底；unit() = next() / 2^32；below(n) = next() % n。
// 全部数值用 double（GDScript float = 64 位，对拍才可对齐）。

#include <cstdint>
#include <cmath>
#include <vector>

namespace rl {

struct RngXs32 {
	uint32_t s = 0x9E3779B9u;

	void seed(uint32_t v) { s = (v == 0u) ? 0x9E3779B9u : v; }

	uint32_t next() {
		s ^= s << 13;
		s ^= s >> 17;
		s ^= s << 5;
		return s;
	}

	// [0,1) 均匀
	double unit() { return (double)next() * (1.0 / 4294967296.0); }

	// [0,n) 整数
	int below(int n) { return (int)(next() % (uint32_t)n); }
};

// 组内 softmax（数值稳定：减组内最大 logit）。probs 长度 5。
inline void softmax5(const double *logits, int group, double *probs) {
	const int off = group * 5;
	double m = logits[off];
	for (int k = 1; k < 5; k++)
		if (logits[off + k] > m) m = logits[off + k];
	double sum = 0.0;
	for (int k = 0; k < 5; k++) {
		probs[k] = std::exp(logits[off + k] - m);
		sum += probs[k];
	}
	for (int k = 0; k < 5; k++) probs[k] /= sum;
}

// 按累计概率采样：u < cum[k] 即取 k，越界兜底取 4（两版逐字一致）。
inline int sample_categorical(const double *probs, RngXs32 &rng) {
	double u = rng.unit();
	double cum = 0.0;
	for (int k = 0; k < 5; k++) {
		cum += probs[k];
		if (u < cum) return k;
	}
	return 4;
}

inline double clampd(double v, double lo, double hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

} // namespace rl

#endif // RL_CORE_MATH_H
