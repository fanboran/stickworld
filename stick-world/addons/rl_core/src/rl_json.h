#ifndef RL_CORE_JSON_H
#define RL_CORE_JSON_H
// rl_core · 迷你 JSON（纯 C++，零 Godot 依赖）。
// 只覆盖本插件存取所需子集：object/array/string/number/bool/null。
// 数字统一 double；序列化时整数值不带小数点。不保序需求 → object 用 vector<pair>（保插入序，输出稳定便于 diff）。

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace rl {

class Json;
using JsonPtr = std::shared_ptr<Json>;

class Json {
public:
	enum Type { NUL, BOOL, NUM, STR, ARR, OBJ };

	Type type = NUL;
	bool b = false;
	double num = 0.0;
	std::string str;
	std::vector<JsonPtr> arr;
	std::vector<std::pair<std::string, JsonPtr>> obj;

	static JsonPtr make(Json::Type t);
	static JsonPtr num_of(double v);
	static JsonPtr str_of(const std::string &s);
	static JsonPtr bool_of(bool v);

	bool has(const std::string &key) const;
	JsonPtr get(const std::string &key) const; // 缺键返回 NUL 空对象指针
	double get_num(const std::string &key, double fallback) const;
	int get_int(const std::string &key, int fallback) const;
	std::string get_str(const std::string &key, const std::string &fallback = "") const;
	void set(const std::string &key, JsonPtr v);

	std::string dump(int indent = 0) const;

	// 解析失败返回 nullptr，err_out 填原因
	static JsonPtr parse(const std::string &text, std::string *err_out = nullptr);
};

} // namespace rl

#endif // RL_CORE_JSON_H
