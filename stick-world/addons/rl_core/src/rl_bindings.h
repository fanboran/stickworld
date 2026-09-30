#ifndef RL_CORE_BINDINGS_H
#define RL_CORE_BINDINGS_H
// rl_core · Godot 绑定层声明（薄壳：持有纯核心对象，方法一一转发；规格与诚实预期见
// rl_env.h / rl_net.h 头注释——绑定层不定义任何新语义）。
//
// 装车精度注意：纯核心全程 double（64 位）；跨 GDScript 边界的观察/权重走
// PackedFloat32Array（32 位装车）。对拍门走纯核心 double 路径已证一致；f32 装车
// 舍入 ~1e-7 属正常损耗，GDScript 侧消费方按此口径。

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "rl_env.h"
#include "rl_net.h"
#include "rl_trainer.h"

namespace godot {

class RLPolicyNet : public RefCounted {
	GDCLASS(RLPolicyNet, RefCounted)

private:
	rl::RLNet net;
	rl::RngXs32 rng;

protected:
	static void _bind_methods();

public:
	void setup(int input_size, int hidden_size, int output_size, int seed);
	void init_weights(int seed);
	PackedFloat32Array forward(const PackedFloat32Array &obs) const;
	Array sample_actions(const PackedFloat32Array &logits); // 用内部 RNG 流采样 3 意图
	void seed_rng(int seed);
	double get_baseline() const;
	void set_baseline(double v);
	int get_baseline_count() const;
	int param_count() const;
	bool save_json(const String &path) const;
	bool load_json(const String &path);

	const rl::RLNet &core() const { return net; }
	rl::RLNet &core_mut() { return net; }
	rl::RngXs32 &rng_mut() { return rng; }
};

class RLBattleEnv : public RefCounted {
	GDCLASS(RLBattleEnv, RefCounted)

private:
	rl::BattleEnv env;

protected:
	static void _bind_methods();

public:
	void load_config(const String &config_json); // "" = 全默认
	void reset(int seed);
	void reset_fixed(int seed, const Dictionary &comp_attacker, const Dictionary &comp_defender);
	void step(const PackedInt32Array &actions_attacker, const PackedInt32Array &actions_defender);
	PackedFloat32Array observe(int side) const;
	Dictionary get_result() const;
	bool is_done() const;
	int get_decisions_made() const;
	Dictionary get_flag_state(int flag_index) const;
	Dictionary get_comp_attacker() const;
	Dictionary get_comp_defender() const;
};

class RLTrainer : public RefCounted {
	GDCLASS(RLTrainer, RefCounted)

private:
	rl::RLTrainer trainer;

protected:
	static void _bind_methods();

public:
	void setup(int seed, const String &config_json); // config "" = 全默认
	void train(int n_iterations);
	Dictionary run_episode(int seed, bool swap_sides);
	Dictionary get_metrics() const;
	bool save_checkpoint(const String &path) const;
	bool load_checkpoint(const String &path);
	Ref<RLPolicyNet> get_net() const;
};

void register_rl_core_types();

} // namespace godot

#endif // RL_CORE_BINDINGS_H
