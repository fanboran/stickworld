#ifndef RL_CORE_MATH_H
#define RL_CORE_MATH_H
// rl_core · 基础数学件（纯 C++，零 Godot 依赖）
//
// RNG 规格（v2，对齐 tests/dev/rl 训练设施）：
//   RngXs32 —— 旧 47 维紧凑规格的 xorshift32，保留给旧对拍件（新协议不再使用）。
//   RngPcg  —— Godot RandomNumberGenerator 语义复刻（标准 pcg32_random_r，默认
//              inc = 0xDA3E39CB94B95BDB；set_seed 只置 state）：selfplay_trainer
//              的 gen_matchup 用它抽对阵，C++ 侧同 seed 同序列才能逐位对拍。
//   hash_djb2 —— Godot 内置 hash(String) 的 djb2 复刻（trainer 种子 = hash("seed|iter")）。
// 全部数值用 double（GDScript float = 64 位，对拍才可对齐）。

#include <cstdint>
#include <cmath>
#include <string>
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

	double unit() { return (double)next() * (1.0 / 4294967296.0); }

	int below(int n) { return (int)(next() % (uint32_t)n); }
};

// Godot RandomNumberGenerator 语义复刻（PCG32）。
// 2026-09-30 实测校准（tests/rng_probe*.gd + test_rng.exe）：
//   - set_seed = pcg32_srandom_r：state=0 → +INC → +=seed → ×MUL+INC；
//   - MUL = 6364136223846793005；INC = 0x280AF6FDEECF029F（Godot 4.7 默认流）；
//   - randi() = 标准 XSH-RR 输出（吃 advance 前 state）——逐位复刻已验证；
//   - randi_range(a,b) = a + rand() % (b-a+1) —— 逐位复刻已验证；
//   - randf()：Godot 4.7 实际一次消耗 2 步、53 位定点（结构未逐位破译），此处以
//     单步 next()/2^32 近似——分布等价、序列不逐位。影响面：gen_matchup 抽到的
//     连续量（占位/配比）与 GDScript 版不同（对阵分布一致）；观察编码对拍走状态
//     注入（零 RNG）、权重衔接为纯前向（零 RNG），均不受影响。
struct RngPcg {
	static const uint64_t PCG_MULT = 6364136223846793005ULL;
	static const uint64_t PCG_INC = 0x280AF6FDEECF029FULL;

	uint64_t state = 0;

	void seed(uint64_t v) {
		// pcg32_srandom_r(initstate=v, initseq=PCG_INC)
		state = 0;
		state = state * PCG_MULT + PCG_INC;
		state += v;
		state = state * PCG_MULT + PCG_INC;
	}

	static uint32_t pcg_output(uint64_t oldstate) {
		uint32_t word = (uint32_t)(((oldstate >> 18u) ^ oldstate) >> 27u); // 先截 32 位再旋转
		uint32_t rot = (uint32_t)(oldstate >> 59u);
		return (word >> rot) | (word << ((32u - rot) & 31u));
	}

	uint32_t next() {
		uint32_t old = (uint32_t)state; // 未用，占位防误用
		(void)old;
		uint64_t prev = state;
		state = state * PCG_MULT + PCG_INC;
		return pcg_output(prev);
	}

	// [0,1) 均匀（近似 Godot randf，见结构体注释）
	double randf() {
		return (double)next() * (1.0 / 4294967296.0);
	}

	// Godot randi_range(from, to)：from + rand() % (to-from+1)，逐位一致
	int randi_range(int from, int to) {
		if (to <= from) return from;
		uint32_t range = (uint32_t)(to - from);
		return from + (int)(next() % (range + 1u));
	}

	// Godot randf_range(from, to)：from + randf() × (to − from)
	double randf_range(double from, double to) {
		return from + randf() * (to - from);
	}
};

// Godot 内置 hash(String) 复刻：djb2，按 UTF-8 字节流，uint32 回绕
inline uint32_t hash_djb2(const std::string &s) {
	uint32_t h = 5381u;
	for (unsigned char c : s) h = h * 33u + (uint32_t)c;
	return h;
}

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

// 带温度 softmax（对齐 policy_net.softmax_slice：t = max(temp, 0.05)，exp((l−mx)/t)）
inline void softmax5_temp(const double *logits, int group, double temp, double *probs) {
	const int off = group * 5;
	double t = temp > 0.05 ? temp : 0.05;
	double m = logits[off];
	for (int k = 1; k < 5; k++)
		if (logits[off + k] > m) m = logits[off + k];
	double sum = 0.0;
	for (int k = 0; k < 5; k++) {
		probs[k] = std::exp((logits[off + k] - m) / t);
		sum += probs[k];
	}
	if (sum <= 0.0) {
		for (int k = 0; k < 5; k++) probs[k] = 0.2;
		return;
	}
	for (int k = 0; k < 5; k++) probs[k] /= sum;
}

// 熵（nats；p≤1e-9 视为 0）
inline double entropy5(const double *probs) {
	double h = 0.0;
	for (int k = 0; k < 5; k++)
		if (probs[k] > 1e-9) h -= probs[k] * std::log(probs[k]);
	return h;
}

inline double clampd(double v, double lo, double hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

inline double norm01(double v) { return clampd(v, 0.0, 1.0); }

} // namespace rl

#endif // RL_CORE_MATH_H
