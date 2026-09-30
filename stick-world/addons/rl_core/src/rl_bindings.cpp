#include "rl_bindings.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "rl_json.h"

using namespace godot;

// ── 工具：String ↔ std::string、rl::Json ↔ 文件 ──

static std::string to_std(const String &s) {
	return s.utf8().get_data();
}

static bool write_text_file(const String &path, const std::string &content) {
	Ref<FileAccess> f = FileAccess::open(path, FileAccess::WRITE);
	if (f.is_null()) return false;
	f->store_string(String(content.c_str()));
	f->close();
	return true;
}

static bool read_text_file(const String &path, std::string &out) {
	Ref<FileAccess> f = FileAccess::open(path, FileAccess::READ);
	if (f.is_null()) return false;
	out = f->get_as_text().utf8().get_data();
	f->close();
	return true;
}

static rl::Comp comp_from_dict(const Dictionary &d) {
	rl::Comp c;
	c.spear = d.get("spear", c.spear);
	c.sword = d.get("sword", c.sword);
	c.staff = d.get("staff", c.staff);
	c.bow = d.get("bow", c.bow);
	return c;
}

static Dictionary comp_to_dict(const rl::Comp &c) {
	Dictionary d;
	d["spear"] = c.spear;
	d["sword"] = c.sword;
	d["staff"] = c.staff;
	d["bow"] = c.bow;
	return d;
}

static PackedFloat32Array vec_to_pfa(const std::vector<double> &v) {
	PackedFloat32Array a;
	a.resize((int)v.size());
	float *w = a.ptrw();
	for (size_t i = 0; i < v.size(); i++) w[i] = (float)v[i];
	return a;
}

// ── RLPolicyNet ──

void RLPolicyNet::setup(int input_size, int hidden_size, int output_size, int seed) {
	net.alloc(input_size, hidden_size, output_size);
	net.init_weights((uint32_t)seed);
	rng.seed((uint32_t)seed ^ 0x3C6EF372u);
}

void RLPolicyNet::init_weights(int seed) {
	net.init_weights((uint32_t)seed);
}

PackedFloat32Array RLPolicyNet::forward(const PackedFloat32Array &obs) const {
	PackedFloat32Array logits;
	if ((int)obs.size() != net.in) return logits; // 维度不符 → 空数组（调用方自查）
	std::vector<double> x(net.in), lg(net.out);
	const float *r = obs.ptr();
	for (int i = 0; i < net.in; i++) x[i] = (double)r[i];
	net.forward(x.data(), lg.data(), nullptr);
	return vec_to_pfa(lg);
}

Array RLPolicyNet::sample_actions(const PackedFloat32Array &logits) {
	Array out;
	if ((int)logits.size() != net.out) return out;
	std::vector<double> lg(net.out);
	const float *r = logits.ptr();
	for (int i = 0; i < net.out; i++) lg[i] = (double)r[i];
	double probs[5];
	int actions[3];
	double lp = 0.0;
	for (int g = 0; g < net.groups; g++) {
		rl::softmax5(lg.data(), g, probs);
		actions[g] = rl::sample_categorical(probs, rng);
		lp += std::log(probs[actions[g]] > 1e-300 ? probs[actions[g]] : 1e-300);
	}
	for (int g = 0; g < net.groups; g++) out.push_back(actions[g]);
	out.push_back(lp); // 末位附带 logπ（GDScript 侧 REINFORCE 可直接用）
	return out;
}

void RLPolicyNet::seed_rng(int seed) {
	rng.seed((uint32_t)seed);
}

double RLPolicyNet::get_baseline() const { return net.baseline; }
void RLPolicyNet::set_baseline(double v) { net.baseline = v; }
int RLPolicyNet::get_baseline_count() const { return (int)net.baseline_count; }

int RLPolicyNet::param_count() const {
	return (int)net.w1.size() + (int)net.b1.size() + (int)net.w2.size() + (int)net.b2.size();
}

bool RLPolicyNet::save_json(const String &path) const {
	return write_text_file(path, net.to_json()->dump(0));
}

bool RLPolicyNet::load_json(const String &path) {
	std::string text;
	if (!read_text_file(path, text)) return false;
	std::string err;
	rl::JsonPtr j = rl::Json::parse(text, &err);
	if (!j) return false;
	return net.from_json(j, &err);
}

void RLPolicyNet::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "input_size", "hidden_size", "output_size", "seed"), &RLPolicyNet::setup);
	ClassDB::bind_method(D_METHOD("init_weights", "seed"), &RLPolicyNet::init_weights);
	ClassDB::bind_method(D_METHOD("forward", "obs"), &RLPolicyNet::forward);
	ClassDB::bind_method(D_METHOD("sample_actions", "logits"), &RLPolicyNet::sample_actions);
	ClassDB::bind_method(D_METHOD("seed_rng", "seed"), &RLPolicyNet::seed_rng);
	ClassDB::bind_method(D_METHOD("get_baseline"), &RLPolicyNet::get_baseline);
	ClassDB::bind_method(D_METHOD("set_baseline", "v"), &RLPolicyNet::set_baseline);
	ClassDB::bind_method(D_METHOD("get_baseline_count"), &RLPolicyNet::get_baseline_count);
	ClassDB::bind_method(D_METHOD("param_count"), &RLPolicyNet::param_count);
	ClassDB::bind_method(D_METHOD("save_json", "path"), &RLPolicyNet::save_json);
	ClassDB::bind_method(D_METHOD("load_json", "path"), &RLPolicyNet::load_json);
}

// ── RLBattleEnv ──

void RLBattleEnv::load_config(const String &config_json) {
	std::string err;
	rl::JsonPtr j;
	if (!config_json.is_empty()) {
		j = rl::Json::parse(to_std(config_json), &err);
		if (!j) return; // 配置解析失败 → 保持当前配置（调用方以默认值兜底）
	}
	env.load_config(j);
}

void RLBattleEnv::reset(int seed) {
	env.reset((uint32_t)seed);
}

void RLBattleEnv::reset_fixed(int seed, const Dictionary &comp_attacker, const Dictionary &comp_defender) {
	env.reset_fixed((uint32_t)seed, comp_from_dict(comp_attacker), comp_from_dict(comp_defender));
}

void RLBattleEnv::step(const PackedInt32Array &actions_attacker, const PackedInt32Array &actions_defender) {
	if (actions_attacker.size() < 3 || actions_defender.size() < 3) return;
	env.step(actions_attacker.ptr(), actions_defender.ptr());
}

PackedFloat32Array RLBattleEnv::observe(int side) const {
	std::vector<double> obs;
	env.observe(side, obs);
	return vec_to_pfa(obs);
}

Dictionary RLBattleEnv::get_result() const {
	rl::EnvResult r = env.result();
	Dictionary d;
	d["winner"] = r.winner;
	d["reward_attacker"] = r.reward_attacker;
	d["reward_defender"] = r.reward_defender;
	d["decisions"] = r.decisions;
	d["attacker_alive"] = r.attacker_alive;
	d["defender_alive"] = r.defender_alive;
	d["flags_attacker"] = r.flags_attacker;
	d["flags_defender"] = r.flags_defender;
	d["timeout"] = r.timeout;
	return d;
}

bool RLBattleEnv::is_done() const { return env.done; }
int RLBattleEnv::get_decisions_made() const { return env.decisions_made; }

Dictionary RLBattleEnv::get_flag_state(int flag_index) const {
	Dictionary d;
	if (flag_index < 0 || flag_index >= 3) return d;
	d["owner"] = (int)env.flag_owner[flag_index];
	d["progress"] = env.flag_prog[flag_index];
	d["capturing"] = env.flag_capturing[flag_index];
	d["contested"] = env.flag_contested[flag_index];
	return d;
}

Dictionary RLBattleEnv::get_comp_attacker() const { return comp_to_dict(env.comp_att); }
Dictionary RLBattleEnv::get_comp_defender() const { return comp_to_dict(env.comp_def); }

void RLBattleEnv::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_config", "config_json"), &RLBattleEnv::load_config);
	ClassDB::bind_method(D_METHOD("reset", "seed"), &RLBattleEnv::reset);
	ClassDB::bind_method(D_METHOD("reset_fixed", "seed", "comp_attacker", "comp_defender"), &RLBattleEnv::reset_fixed);
	ClassDB::bind_method(D_METHOD("step", "actions_attacker", "actions_defender"), &RLBattleEnv::step);
	ClassDB::bind_method(D_METHOD("observe", "side"), &RLBattleEnv::observe);
	ClassDB::bind_method(D_METHOD("get_result"), &RLBattleEnv::get_result);
	ClassDB::bind_method(D_METHOD("is_done"), &RLBattleEnv::is_done);
	ClassDB::bind_method(D_METHOD("get_decisions_made"), &RLBattleEnv::get_decisions_made);
	ClassDB::bind_method(D_METHOD("get_flag_state", "flag_index"), &RLBattleEnv::get_flag_state);
	ClassDB::bind_method(D_METHOD("get_comp_attacker"), &RLBattleEnv::get_comp_attacker);
	ClassDB::bind_method(D_METHOD("get_comp_defender"), &RLBattleEnv::get_comp_defender);
}

// ── RLTrainer ──

void RLTrainer::setup(int seed, const String &config_json) {
	std::string err;
	rl::JsonPtr j;
	if (!config_json.is_empty()) {
		j = rl::Json::parse(to_std(config_json), &err);
		if (!j) j = nullptr;
	}
	trainer.init((uint32_t)seed, j);
}

void RLTrainer::train(int n_iterations) {
	trainer.train(n_iterations);
}

Dictionary RLTrainer::run_episode(int seed, bool swap_sides) {
	Dictionary d;
	int winner = 0;
	double r = trainer.run_episode((uint32_t)seed, swap_sides, &winner);
	d["reward_attacker"] = r;
	d["winner"] = winner;
	return d;
}

Dictionary RLTrainer::get_metrics() const {
	const rl::TrainerMetrics &m = trainer.metrics;
	Dictionary d;
	d["iterations"] = (int64_t)m.iterations;
	d["episodes"] = (int64_t)m.episodes;
	d["mean_return_recent"] = m.mean_return_recent;
	d["attacker_win_rate_recent"] = m.attacker_win_rate_recent;
	d["baseline"] = m.baseline;
	d["baseline_count"] = (int64_t)m.baseline_count;
	d["grad_norm_last"] = m.grad_norm_last;
	d["episodes_per_sec"] = m.episodes_per_sec;
	d["elapsed_sec"] = m.elapsed_sec;
	return d;
}

bool RLTrainer::save_checkpoint(const String &path) const {
	return write_text_file(path, trainer.checkpoint_json()->dump(0));
}

bool RLTrainer::load_checkpoint(const String &path) {
	std::string text;
	if (!read_text_file(path, text)) return false;
	std::string err;
	rl::JsonPtr j = rl::Json::parse(text, &err);
	if (!j) return false;
	return trainer.load_checkpoint_json(j, &err);
}

Ref<RLPolicyNet> RLTrainer::get_net() const {
	// 网络本体归 trainer 持有；这里返回只读壳共享同一 rl::RLNet（引用计数壳包静态存储
	// 不可行——改为返回深拷贝壳，评估用途足够；训练继续走 trainer 自己的那份）
	Ref<RLPolicyNet> shell;
	shell.instantiate();
	shell->core_mut() = trainer.net;
	return shell;
}

void RLTrainer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "seed", "config_json"), &RLTrainer::setup);
	ClassDB::bind_method(D_METHOD("train", "n_iterations"), &RLTrainer::train);
	ClassDB::bind_method(D_METHOD("run_episode", "seed", "swap_sides"), &RLTrainer::run_episode);
	ClassDB::bind_method(D_METHOD("get_metrics"), &RLTrainer::get_metrics);
	ClassDB::bind_method(D_METHOD("save_checkpoint", "path"), &RLTrainer::save_checkpoint);
	ClassDB::bind_method(D_METHOD("load_checkpoint", "path"), &RLTrainer::load_checkpoint);
	ClassDB::bind_method(D_METHOD("get_net"), &RLTrainer::get_net);
}

// ── 注册 ──

namespace godot {

void register_rl_core_types() {
	ClassDB::register_class<RLPolicyNet>();
	ClassDB::register_class<RLBattleEnv>();
	ClassDB::register_class<RLTrainer>();
}

} // namespace godot
