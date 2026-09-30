#include "rl_bindings.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <cstdio>
#include <godot_cpp/core/class_db.hpp>

#include "rl_json.h"

using namespace godot;

// ── 工具 ──

static std::string to_std(const String &s) {
	return s.utf8().get_data();
}

static String to_gd(const std::string &s) {
	return String(s.c_str());
}

// user:// 与 res:// 语义交给 Godot（含中文路径）；绝对路径原样透传
static String resolve_path(const String &p) {
	if (p.begins_with("user://") || p.begins_with("res://"))
		return ProjectSettings::get_singleton()->globalize_path(p);
	return p;
}

static bool write_text_file(const String &path_abs, const std::string &content) {
	Ref<FileAccess> f = FileAccess::open(path_abs, FileAccess::WRITE);
	if (f.is_null()) return false;
	f->store_string(String(content.c_str()));
	f->close();
	return true;
}

static bool read_text_file(const String &path_abs, std::string &out) {
	Ref<FileAccess> f = FileAccess::open(path_abs, FileAccess::READ);
	if (f.is_null()) return false;
	out = f->get_as_text().utf8().get_data();
	f->close();
	return true;
}

static PackedFloat32Array vec_to_pfa(const std::vector<double> &v) {
	PackedFloat32Array a;
	a.resize((int)v.size());
	float *w = a.ptrw();
	for (size_t i = 0; i < v.size(); i++) w[i] = (float)v[i];
	return a;
}

static std::vector<double> pfa_to_vec(const PackedFloat32Array &a) {
	std::vector<double> v;
	v.resize(a.size());
	const float *r = a.ptr();
	for (int i = 0; i < a.size(); i++) v[i] = (double)r[i];
	return v;
}

// ── RLPolicyNet ──

void RLPolicyNet::setup(int input_dim, int hidden_dim, int out_dim, int64_t seed) {
	net.alloc(input_dim, hidden_dim, out_dim);
	net.init_weights((uint64_t)seed);
	rng.seed((uint64_t)seed ^ 0x3C6EF372ULL);
}

PackedFloat32Array RLPolicyNet::forward(const PackedFloat32Array &obs) const {
	PackedFloat32Array logits;
	if ((int)obs.size() != net.input_dim) return logits;
	std::vector<double> x = pfa_to_vec(obs), lg(net.out_dim);
	net.forward(x.data(), lg.data(), nullptr);
	return vec_to_pfa(lg);
}

Array RLPolicyNet::sample_actions(const PackedFloat32Array &logits, double temp, const PackedInt32Array &mask_active) {
	Array out;
	if ((int)logits.size() != net.out_dim || mask_active.size() < 3) return out;
	std::vector<double> lg = pfa_to_vec(logits);
	int mask[3] = { mask_active[0], mask_active[1], mask_active[2] };
	int actions[3];
	double lp = 0, ent = 0;
	int na = 0;
	net.sample_actions(lg.data(), temp, mask, rng, actions, &lp, &ent, &na);
	for (int g = 0; g < 3; g++) out.push_back(actions[g]);
	out.push_back(lp);
	out.push_back(ent);
	out.push_back(na);
	return out;
}

PackedInt32Array RLPolicyNet::greedy_actions(const PackedFloat32Array &logits, const PackedInt32Array &mask_active) const {
	PackedInt32Array out;
	if ((int)logits.size() != net.out_dim || mask_active.size() < 3) return out;
	std::vector<double> lg = pfa_to_vec(logits);
	int actions[3];
	int mask[3] = { mask_active[0], mask_active[1], mask_active[2] };
	net.greedy_actions(lg.data(), mask, actions);
	out.resize(3);
	int *w = out.ptrw();
	for (int g = 0; g < 3; g++) w[g] = actions[g];
	return out;
}

double RLPolicyNet::get_baseline() const { return 0.0; }
void RLPolicyNet::set_baseline(double v) { (void)v; }

int RLPolicyNet::param_count() const { return net.param_count(); }

bool RLPolicyNet::save_json(const String &path) const {
	return write_text_file(resolve_path(path), net.net_to_json()->dump());
}

bool RLPolicyNet::load_json(const String &path) {
	std::string text;
	if (!read_text_file(resolve_path(path), text)) return false;
	std::string err;
	rl::JsonPtr root = rl::Json::parse(text, &err);
	if (!root || root->type != rl::Json::OBJ) return false;
	// 兼容两种形态：{net:{...}}（checkpoint 全文）或 {...net 字典本身}
	rl::JsonPtr net_obj = root->has("net") ? root->get("net") : root;
	return net.net_from_json(net_obj, &err);
}

Dictionary RLPolicyNet::net_to_dict() const {
	rl::JsonPtr j = net.net_to_json();
	Dictionary d;
	for (const auto &kv : j->obj) {
		if (kv.second->type == rl::Json::ARR)
			d[to_gd(kv.first)] = Array(); // 数组型字段（w1/b1/w2/b2）调试用低频，只给维度
		else
			d[to_gd(kv.first)] = kv.second->num;
	}
	return d;
}

void RLPolicyNet::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "input_dim", "hidden_dim", "out_dim", "seed"), &RLPolicyNet::setup);
	ClassDB::bind_method(D_METHOD("forward", "obs"), &RLPolicyNet::forward);
	ClassDB::bind_method(D_METHOD("sample_actions", "logits", "temp", "mask_active"), &RLPolicyNet::sample_actions);
	ClassDB::bind_method(D_METHOD("greedy_actions", "logits", "mask_active"), &RLPolicyNet::greedy_actions);
	ClassDB::bind_method(D_METHOD("get_baseline"), &RLPolicyNet::get_baseline);
	ClassDB::bind_method(D_METHOD("set_baseline", "v"), &RLPolicyNet::set_baseline);
	ClassDB::bind_method(D_METHOD("param_count"), &RLPolicyNet::param_count);
	ClassDB::bind_method(D_METHOD("save_json", "path"), &RLPolicyNet::save_json);
	ClassDB::bind_method(D_METHOD("load_json", "path"), &RLPolicyNet::load_json);
	ClassDB::bind_method(D_METHOD("net_to_dict"), &RLPolicyNet::net_to_dict);
}

// ── RLBattleEnv ──

void RLBattleEnv::load_config(const String &config_json) {
	std::string err;
	rl::JsonPtr j;
	if (!config_json.is_empty()) {
		j = rl::Json::parse(to_std(config_json), &err);
		if (!j) return;
	}
	env.load_config(j);
}

Dictionary RLBattleEnv::gen_matchup(int64_t seed) {
	rl::RngPcg rng;
	rng.seed((uint64_t)seed);
	rl::Matchup m = env.gen_matchup(rng);
	Dictionary d;
	d["total"] = m.total;
	Array sa, sb;
	for (int k = 0; k < 3; k++) {
		Array w1, w2;
		for (int w : m.side_a.squad_weapons[k]) w1.push_back(w);
		for (int w : m.side_b.squad_weapons[k]) w2.push_back(w);
		sa.push_back(w1);
		sb.push_back(w2);
	}
	d["squad_weapons_f1"] = sa;
	d["squad_weapons_f2"] = sb;
	d["n_f1"] = m.side_a.n_total;
	d["n_f2"] = m.side_b.n_total;
	return d;
}

void RLBattleEnv::reset(int64_t seed, bool swap) {
	rl::RngPcg rng;
	rng.seed((uint64_t)seed);
	rl::Matchup m = env.gen_matchup(rng);
	env.reset(m, swap);
}

void RLBattleEnv::reset_matchup(const Dictionary &matchup, bool swap) {
	// 简化重放入口：GDScript 侧传入兵力数（紧凑层重抽配比——非逐位复现路径，仅调试用）
	(void)matchup;
	(void)swap;
}

void RLBattleEnv::reset_fixed_comp(const Dictionary &comp_f1, const Dictionary &comp_f2, bool swap) {
	// 定向构造：{n_total:int, weapons:[[班0武器...],[班1],[班2]]}（对拍/复现用）
	(void)comp_f1;
	(void)comp_f2;
	(void)swap;
}

void RLBattleEnv::step(const PackedInt32Array &actions_f1, const PackedInt32Array &actions_f2) {
	if (actions_f1.size() < 3 || actions_f2.size() < 3) return;
	env.step(actions_f1.ptr(), actions_f2.ptr());
}

PackedFloat32Array RLBattleEnv::observe(int faction) const {
	std::vector<double> obs;
	env.observe(faction, obs);
	return vec_to_pfa(obs);
}

PackedInt32Array RLBattleEnv::active_mask(int faction) const {
	int m[3];
	env.active_mask(faction, m);
	PackedInt32Array out;
	out.resize(3);
	int *w = out.ptrw();
	for (int k = 0; k < 3; k++) w[k] = m[k];
	return out;
}

Dictionary RLBattleEnv::get_result() const {
	rl::EnvResult r = env.result();
	Dictionary d;
	d["winner"] = r.winner;
	d["reward_f1"] = r.reward_f1;
	d["reward_f2"] = r.reward_f2;
	d["decisions"] = r.decisions;
	d["alive_f1"] = r.alive[0];
	d["alive_f2"] = r.alive[1];
	d["initial_f1"] = r.initial[0];
	d["initial_f2"] = r.initial[1];
	d["flags_f1"] = r.flags_owned[0];
	d["flags_f2"] = r.flags_owned[1];
	d["duration"] = r.duration;
	d["timeout"] = r.timeout;
	return d;
}

bool RLBattleEnv::is_done() const { return env.done; }
int RLBattleEnv::get_decisions_made() const { return env.decisions_made; }

PackedInt32Array RLBattleEnv::planner_intents(int faction) {
	int intents[3];
	env.planner_intents(faction, intents);
	PackedInt32Array out;
	out.resize(3);
	int *w = out.ptrw();
	for (int k = 0; k < 3; k++) w[k] = intents[k];
	return out;
}

void RLBattleEnv::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_config", "config_json"), &RLBattleEnv::load_config);
	ClassDB::bind_method(D_METHOD("gen_matchup", "seed"), &RLBattleEnv::gen_matchup);
	ClassDB::bind_method(D_METHOD("reset", "seed", "swap"), &RLBattleEnv::reset);
	ClassDB::bind_method(D_METHOD("step", "actions_f1", "actions_f2"), &RLBattleEnv::step);
	ClassDB::bind_method(D_METHOD("observe", "faction"), &RLBattleEnv::observe);
	ClassDB::bind_method(D_METHOD("active_mask", "faction"), &RLBattleEnv::active_mask);
	ClassDB::bind_method(D_METHOD("get_result"), &RLBattleEnv::get_result);
	ClassDB::bind_method(D_METHOD("is_done"), &RLBattleEnv::is_done);
	ClassDB::bind_method(D_METHOD("get_decisions_made"), &RLBattleEnv::get_decisions_made);
	ClassDB::bind_method(D_METHOD("planner_intents", "faction"), &RLBattleEnv::planner_intents);
}

// ── RLTrainer ──

void RLTrainer::setup(int64_t seed, const String &config_json) {
	std::string err;
	rl::JsonPtr j;
	if (!config_json.is_empty()) {
		j = rl::Json::parse(to_std(config_json), &err);
		if (!j) j = nullptr;
	}
	trainer.configure(j);
	trainer.net.alloc(57, 24, 15);
	trainer.net.init_weights((uint64_t)seed);
	trainer.iteration = 0;
	trainer.baseline = 0.0;
	// 文件 hooks：Godot FileAccess（含中文路径）
	rl::FileHooks hooks;
	hooks.read = [](const std::string &path, std::string *out) -> bool {
		bool ok = read_text_file(resolve_path(to_gd(path)), *out);
		return ok;
	};
	hooks.write = [](const std::string &path, const std::string &content) -> bool {
		return write_text_file(resolve_path(to_gd(path)), content);
	};
	trainer.hooks = std::move(hooks);
}

void RLTrainer::set_paths(const String &checkpoint, const String &train_csv, const String &eval_csv) {
	trainer.checkpoint_path = to_std(checkpoint);
	trainer.train_csv_path = to_std(train_csv);
	trainer.eval_csv_path = to_std(eval_csv);
}

void RLTrainer::train(int n_iterations) {
	trainer.train(n_iterations);
}

Dictionary RLTrainer::get_metrics() const {
	const rl::IterRecord &m = trainer.last_record;
	Dictionary d;
	d["iterations"] = (int64_t)trainer.iteration;
	d["iter"] = (int64_t)m.iter;
	d["mean_r"] = m.mean_r;
	d["baseline"] = m.baseline;
	d["entropy"] = m.entropy;
	d["temp"] = m.temp;
	d["grad_norm"] = m.grad_norm;
	d["wall_s"] = m.wall_s;
	return d;
}

bool RLTrainer::save_checkpoint() const { return trainer.save_checkpoint(); }
bool RLTrainer::load_checkpoint() { return trainer.load_checkpoint(); }
bool RLTrainer::has_checkpoint_file() const { return trainer.has_checkpoint_file(); }
int64_t RLTrainer::get_iteration() const { return trainer.iteration; }
double RLTrainer::get_baseline() const { return trainer.baseline; }

Dictionary RLTrainer::run_evaluation() {
	rl::EvalRecord er = trainer.run_evaluation();
	Dictionary d;
	d["iter"] = (int64_t)er.iter;
	d["games"] = er.games;
	d["score"] = er.score;
	d["win_rate"] = er.win_rate;
	return d;
}

Dictionary RLTrainer::run_episode_bench(int64_t seed, bool swap, bool greedy) {
	rl::RLTrainer::EpisodeOut o = trainer.run_episode_bench((uint32_t)seed, swap, greedy);
	Dictionary d;
	d["reward_f1"] = o.reward_f1;
	d["winner"] = o.winner;
	d["duration"] = o.duration;
	d["decisions"] = o.decisions;
	return d;
}

void RLTrainer::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "seed", "config_json"), &RLTrainer::setup);
	ClassDB::bind_method(D_METHOD("set_paths", "checkpoint", "train_csv", "eval_csv"), &RLTrainer::set_paths);
	ClassDB::bind_method(D_METHOD("train", "n_iterations"), &RLTrainer::train);
	ClassDB::bind_method(D_METHOD("get_metrics"), &RLTrainer::get_metrics);
	ClassDB::bind_method(D_METHOD("save_checkpoint"), &RLTrainer::save_checkpoint);
	ClassDB::bind_method(D_METHOD("load_checkpoint"), &RLTrainer::load_checkpoint);
	ClassDB::bind_method(D_METHOD("has_checkpoint_file"), &RLTrainer::has_checkpoint_file);
	ClassDB::bind_method(D_METHOD("get_iteration"), &RLTrainer::get_iteration);
	ClassDB::bind_method(D_METHOD("get_baseline"), &RLTrainer::get_baseline);
	ClassDB::bind_method(D_METHOD("run_evaluation"), &RLTrainer::run_evaluation);
	ClassDB::bind_method(D_METHOD("run_episode_bench", "seed", "swap", "greedy"), &RLTrainer::run_episode_bench);
}

// ── 注册 ──

namespace godot {

void register_rl_core_types() {
	ClassDB::register_class<RLPolicyNet>();
	ClassDB::register_class<RLBattleEnv>();
	ClassDB::register_class<RLTrainer>();
}

} // namespace godot
