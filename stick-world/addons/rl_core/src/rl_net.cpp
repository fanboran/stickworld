#include "rl_net.h"

#include <cmath>

namespace rl {

void RLNet::alloc(int in_dim, int hid_dim, int out_dim) {
	input_dim = in_dim;
	hidden_dim = hid_dim;
	out_dim = out_dim;
	w1.assign((size_t)hidden_dim * input_dim, 0.0);
	b1.assign(hidden_dim, 0.0);
	w2.assign((size_t)out_dim * hidden_dim, 0.0);
	b2.assign(out_dim, 0.0);
}

void RLNet::init_weights(uint64_t seed) {
	RngPcg rng;
	rng.seed(seed);
	// 顺序与 policy_net.randomize_weights 一致：w1 → b1(0) → w2 → b2(0)
	double lim1 = std::sqrt(6.0 / (double)(hidden_dim + input_dim));
	for (auto &w : w1) w = rng.randf_range(-lim1, lim1);
	for (auto &b : b1) b = 0.0;
	double lim2 = std::sqrt(6.0 / (double)(out_dim + hidden_dim));
	for (auto &w : w2) w = rng.randf_range(-lim2, lim2);
	for (auto &b : b2) b = 0.0;
}

void RLNet::forward(const double *obs, double *logits, double *hidden_out) const {
	std::vector<double> h_local;
	double *h = hidden_out;
	if (h == nullptr) {
		h_local.resize(hidden_dim);
		h = h_local.data();
	}
	for (int j = 0; j < hidden_dim; j++) {
		double s = 0.0;
		const double *row = &w1[(size_t)j * input_dim];
		for (int i = 0; i < input_dim; i++) s += row[i] * obs[i];
		h[j] = (s + b1[j]) > 0.0 ? (s + b1[j]) : 0.0;
	}
	for (int k = 0; k < out_dim; k++) {
		double s = 0.0;
		const double *row = &w2[(size_t)k * hidden_dim];
		for (int j = 0; j < hidden_dim; j++) s += row[j] * h[j];
		logits[k] = s + b2[k];
	}
}

void RLNet::softmax_slice(const double *logits, int squad, double temp, double *probs5) const {
	softmax5_temp(logits, squad, temp, probs5);
}

void RLNet::sample_actions(const double *logits, double temp, const int *mask_active,
		RngPcg &rng, int *actions, double *logprob_out, double *entropy_out, int *n_active_out) const {
	double logprob = 0.0, entropy = 0.0;
	int n_active = 0;
	double probs[5];
	for (int s = 0; s < N_SQUADS; s++) {
		if (mask_active[s] == 0) {
			actions[s] = 0;
			continue;
		}
		softmax_slice(logits, s, temp, probs);
		double roll = rng.randf();
		double acc = 0.0;
		int picked = N_ACTIONS - 1;
		for (int a = 0; a < N_ACTIONS; a++) {
			acc += probs[a];
			if (roll <= acc) { // 边界语义 <=，与 GDScript 版逐字一致
				picked = a;
				break;
			}
		}
		actions[s] = picked;
		logprob += std::log(probs[picked] > 1e-9 ? probs[picked] : 1e-9);
		entropy += entropy5(probs);
		n_active++;
	}
	if (logprob_out) *logprob_out = logprob;
	if (entropy_out) *entropy_out = entropy;
	if (n_active_out) *n_active_out = n_active;
}

void RLNet::greedy_actions(const double *logits, const int *mask_active, int *actions) const {
	for (int s = 0; s < N_SQUADS; s++) {
		if (mask_active[s] == 0) {
			actions[s] = 0;
			continue;
		}
		int base = s * N_ACTIONS;
		int best = 0;
		for (int a = 1; a < N_ACTIONS; a++)
			if (logits[base + a] > logits[base + best]) best = a;
		actions[s] = best;
	}
}

double RLNet::train_step(const std::vector<Sample> &samples, double lr, double clip_norm) {
	int n = (int)samples.size();
	if (n == 0) return 0.0;
	std::vector<double> gw1(w1.size(), 0.0), gb1(b1.size(), 0.0);
	std::vector<double> gw2(w2.size(), 0.0), gb2(b2.size(), 0.0);
	std::vector<double> h(hidden_dim), z1(hidden_dim), gh(hidden_dim);
	for (const Sample &sp : samples) {
		const double *obs = sp.obs.data();
		const double *dlogits = sp.dlogits.data();
		for (int j = 0; j < hidden_dim; j++) {
			double s = 0.0;
			const double *row = &w1[(size_t)j * input_dim];
			for (int i = 0; i < input_dim; i++) s += row[i] * obs[i];
			z1[j] = s;
			h[j] = s > 0.0 ? s : 0.0;
		}
		for (int j = 0; j < hidden_dim; j++) gh[j] = 0.0;
		for (int k = 0; k < out_dim; k++) {
			double gk = dlogits[k];
			if (gk == 0.0) continue;
			const double *row = &w2[(size_t)k * hidden_dim];
			for (int j = 0; j < hidden_dim; j++) {
				gw2[(size_t)k * hidden_dim + j] += gk * h[j];
				gh[j] += row[j] * gk;
			}
		}
		for (int j = 0; j < hidden_dim; j++) {
			if (z1[j] <= 0.0) continue;
			double gj = gh[j];
			if (gj == 0.0) continue;
			double *grow = &gw1[(size_t)j * input_dim];
			for (int i = 0; i < input_dim; i++) grow[i] += gj * obs[i];
			gb1[j] += gj;
		}
		for (int k = 0; k < out_dim; k++) gb2[k] += dlogits[k];
	}
	// 均值 → 全局范数 → 裁剪缩放 → 应用（与 policy_net.train_step 逐字一致）
	auto mean_sq = [n](const std::vector<double> &g) {
		double s = 0.0;
		for (double v : g) {
			double m = v / (double)n;
			s += m * m;
		}
		return s;
	};
	double sq = mean_sq(gw1) + mean_sq(gb1) + mean_sq(gw2) + mean_sq(gb2);
	double grad_norm = std::sqrt(sq);
	double scale = lr;
	if (clip_norm > 0.0 && grad_norm > clip_norm) scale = lr * clip_norm / (grad_norm > 1e-9 ? grad_norm : 1e-9);
	auto apply = [&](std::vector<double> &param, const std::vector<double> &grad) {
		for (size_t i = 0; i < param.size(); i++) param[i] -= grad[i] / (double)n * scale;
	};
	apply(w1, gw1);
	apply(b1, gb1);
	apply(w2, gw2);
	apply(b2, gb2);
	return grad_norm;
}

JsonPtr RLNet::net_to_json() const {
	auto j = Json::make(Json::OBJ);
	j->set("input_dim", Json::num_of(input_dim));
	j->set("hidden_dim", Json::num_of(hidden_dim));
	j->set("out_dim", Json::num_of(out_dim));
	auto flat = [](const std::vector<double> &v) {
		auto arr = Json::make(Json::ARR);
		for (double x : v) arr->arr.push_back(Json::num_of(x));
		return arr;
	};
	j->set("w1", flat(w1));
	j->set("b1", flat(b1));
	j->set("w2", flat(w2));
	j->set("b2", flat(b2));
	return j;
}

bool RLNet::net_from_json(const JsonPtr &j, std::string *err_out) {
	auto bad = [err_out](const std::string &m) {
		if (err_out != nullptr) *err_out = m;
		return false;
	};
	if (!j || j->type != Json::OBJ) return bad("net not an object");
	int ni = j->get_int("input_dim", 0), nh = j->get_int("hidden_dim", 0), no = j->get_int("out_dim", 0);
	if (ni <= 0 || nh <= 0 || no <= 0) return bad("bad dims");
	alloc(ni, nh, no);
	auto flat = [&](const char *key, std::vector<double> &dst) -> bool {
		JsonPtr a = j->get(key);
		if (!a || a->type != Json::ARR || (int)a->arr.size() != (int)dst.size())
			return bad(std::string(key) + " shape");
		for (size_t i = 0; i < dst.size(); i++) dst[i] = a->arr[i]->num;
		return true;
	};
	if (!flat("w1", w1)) return false;
	if (!flat("b1", b1)) return false;
	if (!flat("w2", w2)) return false;
	if (!flat("b2", b2)) return false;
	return true;
}

} // namespace rl
