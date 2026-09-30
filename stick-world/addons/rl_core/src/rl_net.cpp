#include "rl_net.h"

#include <cmath>

namespace rl {

void RLNet::alloc(int in_dim, int hid_dim, int out_dim) {
	in = in_dim;
	hid = hid_dim;
	out = out_dim;
	w1.assign((size_t)hid * in, 0.0);
	b1.assign(hid, 0.0);
	w2.assign((size_t)out * hid, 0.0);
	b2.assign(out, 0.0);
	g1 = w1;
	gb1 = b1;
	g2 = w2;
	gb2 = b2;
	m1 = w1;
	mb1 = b1;
	m2 = w2;
	mb2 = b2;
	v1 = w1;
	vb1 = b1;
	v2 = w2;
	vb2 = b2;
	adam_t = 0;
	baseline = 0.0;
	baseline_count = 0;
}

void RLNet::init_weights(uint32_t seed) {
	RngXs32 rng;
	rng.seed(seed ^ 0x5BD1E995u);
	double lim1 = std::sqrt(6.0 / (double)(in + hid));
	for (auto &w : w1) w = (rng.unit() * 2.0 - 1.0) * lim1;
	double lim2 = std::sqrt(6.0 / (double)(hid + out));
	for (auto &w : w2) w = (rng.unit() * 2.0 - 1.0) * lim2;
	for (auto &b : b1) b = 0.0;
	for (auto &b : b2) b = 0.0;
	adam_t = 0;
	baseline = 0.0;
	baseline_count = 0;
}

void RLNet::forward(const double *obs, double *logits, double *hidden_out) const {
	std::vector<double> h_local;
	double *h = hidden_out;
	if (h == nullptr) {
		h_local.resize(hid);
		h = h_local.data();
	}
	for (int j = 0; j < hid; j++) {
		double s = b1[j];
		const double *row = &w1[(size_t)j * in];
		for (int i = 0; i < in; i++) s += row[i] * obs[i];
		h[j] = s > 0.0 ? s : 0.0;
	}
	for (int o = 0; o < out; o++) {
		double s = b2[o];
		const double *row = &w2[(size_t)o * hid];
		for (int j = 0; j < hid; j++) s += row[j] * h[j];
		logits[o] = s;
	}
}

void RLNet::probs_for(const double *logits, int group, double *probs5) const {
	softmax5(logits, group, probs5);
}

void RLNet::sample_actions(const double *logits, RngXs32 &rng, int *actions, double *logprob_out) const {
	double probs[5];
	double lp = 0.0;
	for (int g = 0; g < groups; g++) {
		probs_for(logits, g, probs);
		int a = sample_categorical(probs, rng);
		actions[g] = a;
		lp += std::log(probs[a] > 1e-300 ? probs[a] : 1e-300);
	}
	if (logprob_out != nullptr) *logprob_out = lp;
}

void RLNet::accumulate_grad(const double *obs, const int *actions, double advantage) {
	// 重算前向（轨迹缓存省内存：一条样本两次前向，代价可忽略）
	std::vector<double> h(hid), logits(out), probs(5);
	forward(obs, logits.data(), h.data());

	std::vector<double> dlogit(out, 0.0);
	std::vector<double> dh(hid, 0.0);
	for (int g = 0; g < groups; g++) {
		probs_for(logits.data(), g, probs.data());
		for (int k = 0; k < apg; k++) {
			int o = g * apg + k;
			double d = probs[k];
			if (k == actions[g]) d -= 1.0; // ∂(−A·logπ_a)/∂logit_o = A·(p_o − 1{o=a})
			dlogit[o] = d * advantage;
		}
	}
	// W2/b2 与隐层反传
	for (int o = 0; o < out; o++) {
		double dl = dlogit[o];
		if (dl == 0.0) continue;
		double *grow = &g2[(size_t)o * hid];
		for (int j = 0; j < hid; j++) {
			grow[j] += dl * h[j];
			dh[j] += dl * w2[(size_t)o * hid + j];
		}
		gb2[o] += dl;
	}
	// W1/b1（relu 掩码 = h[j] > 0）
	for (int j = 0; j < hid; j++) {
		if (h[j] <= 0.0 || dh[j] == 0.0) continue;
		double *grow = &g1[(size_t)j * in];
		double dj = dh[j];
		for (int i = 0; i < in; i++) grow[i] += dj * obs[i];
		gb1[j] += dj;
	}
}

void RLNet::adam_step(double lr, double batch_count) {
	if (batch_count <= 0.0) return;
	const double inv = 1.0 / batch_count;
	const double b1p = 0.9, b2p = 0.999, eps = 1e-8;
	adam_t++;
	const double bc1 = 1.0 - std::pow(b1p, (double)adam_t);
	const double bc2 = 1.0 - std::pow(b2p, (double)adam_t);
	auto step = [lr, inv, b1p, b2p, eps, bc1, bc2](std::vector<double> &p, std::vector<double> &g,
			std::vector<double> &m, std::vector<double> &vv) {
		for (size_t k = 0; k < p.size(); k++) {
			double grad = g[k] * inv;
			m[k] = b1p * m[k] + (1.0 - b1p) * grad;
			vv[k] = b2p * vv[k] + (1.0 - b2p) * grad * grad;
			p[k] -= lr * (m[k] / bc1) / (std::sqrt(vv[k] / bc2) + eps);
			g[k] = 0.0;
		}
	};
	step(w1, g1, m1, v1);
	step(b1, gb1, mb1, vb1);
	step(w2, g2, m2, v2);
	step(b2, gb2, mb2, vb2);
}

JsonPtr RLNet::to_json() const {
	auto j = Json::make(Json::OBJ);
	j->set("format", Json::str_of("rl_core.policy_net"));
	j->set("version", Json::num_of(1));
	j->set("input_size", Json::num_of(in));
	j->set("hidden_size", Json::num_of(hid));
	j->set("output_size", Json::num_of(out));
	j->set("output_groups", Json::num_of(groups));
	j->set("actions_per_group", Json::num_of(apg));
	j->set("activation", Json::str_of("relu"));
	auto arr1 = Json::make(Json::ARR);
	for (int r = 0; r < hid; r++) {
		auto row = Json::make(Json::ARR);
		for (int c = 0; c < in; c++) row->arr.push_back(Json::num_of(w1[(size_t)r * in + c]));
		arr1->arr.push_back(row);
	}
	j->set("w1", arr1);
	auto ab1 = Json::make(Json::ARR);
	for (int r = 0; r < hid; r++) ab1->arr.push_back(Json::num_of(b1[r]));
	j->set("b1", ab1);
	auto arr2 = Json::make(Json::ARR);
	for (int r = 0; r < out; r++) {
		auto row = Json::make(Json::ARR);
		for (int c = 0; c < hid; c++) row->arr.push_back(Json::num_of(w2[(size_t)r * hid + c]));
		arr2->arr.push_back(row);
	}
	j->set("w2", arr2);
	auto ab2 = Json::make(Json::ARR);
	for (int r = 0; r < out; r++) ab2->arr.push_back(Json::num_of(b2[r]));
	j->set("b2", ab2);
	j->set("baseline", Json::num_of(baseline));
	j->set("baseline_count", Json::num_of((double)baseline_count));
	return j;
}

bool RLNet::from_json(const JsonPtr &j, std::string *err_out) {
	auto bad = [err_out](const std::string &m) {
		if (err_out != nullptr) *err_out = m;
		return false;
	};
	if (!j || j->type != Json::OBJ) return bad("not an object");
	if (j->get_str("format") != "rl_core.policy_net") return bad("format mismatch");
	if (j->get_int("version", -1) != 1) return bad("version mismatch");
	int ni = j->get_int("input_size", 0);
	int nh = j->get_int("hidden_size", 0);
	int no = j->get_int("output_size", 0);
	if (ni <= 0 || nh <= 0 || no <= 0) return bad("bad dims");
	alloc(ni, nh, no);
	auto rd2 = [&](const char *key, std::vector<double> &dst, int rows, int cols) -> bool {
		JsonPtr a = j->get(key);
		if (!a || a->type != Json::ARR || (int)a->arr.size() != rows) return bad(std::string(key) + " shape");
		for (int r = 0; r < rows; r++) {
			JsonPtr row = a->arr[r];
			if (!row || row->type != Json::ARR || (int)row->arr.size() != cols) return bad(std::string(key) + " row shape");
			for (int c = 0; c < cols; c++) dst[(size_t)r * cols + c] = row->arr[c]->num;
		}
		return true;
	};
	auto rd1 = [&](const char *key, std::vector<double> &dst, int n) -> bool {
		JsonPtr a = j->get(key);
		if (!a || a->type != Json::ARR || (int)a->arr.size() != n) return bad(std::string(key) + " shape");
		for (int r = 0; r < n; r++) dst[r] = a->arr[r]->num;
		return true;
	};
	if (!rd2("w1", w1, hid, in)) return false;
	if (!rd1("b1", b1, hid)) return false;
	if (!rd2("w2", w2, out, hid)) return false;
	if (!rd1("b2", b2, out)) return false;
	baseline = j->get_num("baseline", 0.0);
	baseline_count = j->get_int("baseline_count", 0);
	return true;
}

} // namespace rl
