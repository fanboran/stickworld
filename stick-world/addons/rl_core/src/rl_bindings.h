#ifndef RL_CORE_BINDINGS_H
#define RL_CORE_BINDINGS_H
// rl_core · Godot 绑定层声明 v2（薄壳：持有纯核心对象，方法一一转发；规格与
// 诚实预期见 rl_env.h / rl_net.h / rl_trainer.h 头注释——绑定层不定义新语义）。
//
// 精度口径：纯核心全程 double；跨 GDScript 边界的观察/权重走
// PackedFloat32Array（f32 装车，~1e-7 舍入属正常损耗；对拍与权重衔接在
// GDScript 侧 policy_net.gd（float32 数组）与 C++ double 间比对按 1e-6 容差）。

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
	rl::RngPcg rng;

protected:
	static void _bind_methods();

public:
	void setup(int input_dim, int hidden_dim, int out_dim, int64_t seed);
	PackedFloat32Array forward(const PackedFloat32Array &obs) const;
	Array sample_actions(const PackedFloat32Array &logits, double temp, const PackedInt32Array &mask_active);
	PackedInt32Array greedy_actions(const PackedFloat32Array &logits, const PackedInt32Array &mask_active) const;
	double get_baseline() const;
	void set_baseline(double v);
	int param_count() const;
	bool save_json(const String &path) const;      // 阿尔法 net 字典格式
	bool load_json(const String &path);            // 装载 user://rl/checkpoint.json 亦可
	Dictionary net_to_dict() const;                // 与 policy_net.to_dict 同形（调试/互验）

	const rl::RLNet &core() const { return net; }
	rl::RLNet &core_mut() { return net; }
	rl::RngPcg &rng_mut() { return rng; }
};

class RLBattleEnv : public RefCounted {
	GDCLASS(RLBattleEnv, RefCounted)

private:
	rl::BattleEnv env;

protected:
	static void _bind_methods();

public:
	void load_config(const String &config_json);
	Dictionary gen_matchup(int64_t seed); // 内部建 RngPcg（对拍/调试用；训练走 trainer）
	void reset(int64_t seed, bool swap);  // 内部 gen_matchup+reset（同上）
	void reset_matchup(const Dictionary &matchup, bool swap);
	void reset_fixed_comp(const Dictionary &comp_f1, const Dictionary &comp_f2, bool swap);
	void step(const PackedInt32Array &actions_f1, const PackedInt32Array &actions_f2);
	PackedFloat32Array observe(int faction) const;
	PackedInt32Array active_mask(int faction) const;
	Dictionary get_result() const;
	bool is_done() const;
	int get_decisions_made() const;
	PackedInt32Array planner_intents(int faction); // 军师规划器镜像（评估对手）
};

class RLTrainer : public RefCounted {
	GDCLASS(RLTrainer, RefCounted)

private:
	rl::RLTrainer trainer;

protected:
	static void _bind_methods();

public:
	void setup(int64_t seed, const String &config_json);
	void set_paths(const String &checkpoint, const String &train_csv, const String &eval_csv);
	void train(int n_iterations);
	Dictionary get_metrics() const;
	bool save_checkpoint() const;
	bool load_checkpoint(); // 假 = 无档/损坏/维度不符（从头训）
	bool has_checkpoint_file() const;
	int64_t get_iteration() const;
	double get_baseline() const;
	Dictionary run_evaluation();
	Dictionary run_episode_bench(int64_t seed, bool swap, bool greedy);
};

void register_rl_core_types();

} // namespace godot

#endif // RL_CORE_BINDINGS_H
