#include "rl_json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace rl {

JsonPtr Json::make(Type t) {
	auto j = std::make_shared<Json>();
	j->type = t;
	return j;
}

JsonPtr Json::num_of(double v) {
	auto j = make(NUM);
	j->num = v;
	return j;
}

JsonPtr Json::str_of(const std::string &s) {
	auto j = make(STR);
	j->str = s;
	return j;
}

JsonPtr Json::bool_of(bool v) {
	auto j = make(BOOL);
	j->b = v;
	return j;
}

bool Json::has(const std::string &key) const {
	for (const auto &kv : obj)
		if (kv.first == key) return true;
	return false;
}

JsonPtr Json::get(const std::string &key) const {
	for (const auto &kv : obj)
		if (kv.first == key) return kv.second;
	return make(NUL);
}

double Json::get_num(const std::string &key, double fallback) const {
	for (const auto &kv : obj)
		if (kv.first == key && kv.second->type == NUM) return kv.second->num;
	return fallback;
}

int Json::get_int(const std::string &key, int fallback) const {
	return (int)get_num(key, (double)fallback);
}

std::string Json::get_str(const std::string &key, const std::string &fallback) const {
	for (const auto &kv : obj)
		if (kv.first == key && kv.second->type == STR) return kv.second->str;
	return fallback;
}

void Json::set(const std::string &key, JsonPtr v) {
	for (auto &kv : obj)
		if (kv.first == key) {
			kv.second = v;
			return;
		}
	obj.emplace_back(key, v);
}

static std::string esc(const std::string &s) {
	std::string out;
	out.reserve(s.size() + 8);
	for (char c : s) {
		switch (c) {
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if ((unsigned char)c < 0x20) {
					char buf[8];
					std::snprintf(buf, sizeof(buf), "\\u%04x", c);
					out += buf;
				} else
					out += c;
		}
	}
	return out;
}

static std::string num_str(double v) {
	if (v == (double)(int64_t)v && std::fabs(v) < 1e15) {
		char buf[32];
		std::snprintf(buf, sizeof(buf), "%lld", (long long)v);
		return buf;
	}
	char buf[40];
	std::snprintf(buf, sizeof(buf), "%.17g", v);
	return buf;
}

static void dump_impl(const Json &j, int indent, int depth, std::string &out) {
	const std::string pad = indent > 0 ? std::string((size_t)(indent * (depth + 1)), ' ') : "";
	const std::string pad_end = indent > 0 ? std::string((size_t)(indent * depth), ' ') : "";
	const std::string nl = indent > 0 ? "\n" : "";
	const std::string colon = indent > 0 ? ": " : ":";
	switch (j.type) {
		case Json::NUL: out += "null"; break;
		case Json::BOOL: out += j.b ? "true" : "false"; break;
		case Json::NUM: out += num_str(j.num); break;
		case Json::STR: out += "\"" + esc(j.str) + "\""; break;
		case Json::ARR: {
			out += "[";
			if (!j.arr.empty()) {
				out += nl + pad;
				for (size_t i = 0; i < j.arr.size(); i++) {
					if (i > 0) out += "," + nl + pad;
					dump_impl(*j.arr[i], indent, depth + 1, out);
				}
				out += nl + pad_end;
			}
			out += "]";
			break;
		}
		case Json::OBJ: {
			out += "{";
			if (!j.obj.empty()) {
				out += nl + pad;
				for (size_t i = 0; i < j.obj.size(); i++) {
					if (i > 0) out += "," + nl + pad;
					out += "\"" + esc(j.obj[i].first) + "\"" + colon;
					dump_impl(*j.obj[i].second, indent, depth + 1, out);
				}
				out += nl + pad_end;
			}
			out += "}";
			break;
		}
	}
}

std::string Json::dump(int indent) const {
	std::string out;
	dump_impl(*this, indent, 0, out);
	return out;
}

// ── 解析器 ─────────────────────────────────────────────

namespace {
struct Parser {
	const char *p = nullptr;
	const char *end = nullptr;
	std::string err;

	void skip_ws() {
		while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	}

	bool fail(const std::string &m) {
		if (err.empty()) err = m;
		return false;
	}

	JsonPtr value() {
		skip_ws();
		if (p >= end) {
			fail("unexpected end");
			return nullptr;
		}
		char c = *p;
		if (c == '{') return object();
		if (c == '[') return array();
		if (c == '"') {
			std::string s;
			if (!string_lit(s)) return nullptr;
			return Json::str_of(s);
		}
		if (c == 't') {
			if (end - p >= 4 && std::strncmp(p, "true", 4) == 0) {
				p += 4;
				return Json::bool_of(true);
			}
			fail("bad literal");
			return nullptr;
		}
		if (c == 'f') {
			if (end - p >= 5 && std::strncmp(p, "false", 5) == 0) {
				p += 5;
				return Json::bool_of(false);
			}
			fail("bad literal");
			return nullptr;
		}
		if (c == 'n') {
			if (end - p >= 4 && std::strncmp(p, "null", 4) == 0) {
				p += 4;
				return Json::make(Json::NUL);
			}
			fail("bad literal");
			return nullptr;
		}
		return number();
	}

	JsonPtr object() {
		p++; // {
		auto j = Json::make(Json::OBJ);
		skip_ws();
		if (p < end && *p == '}') {
			p++;
			return j;
		}
		while (p < end) {
			skip_ws();
			std::string key;
			if (*p != '"' || !string_lit(key)) return nullptr;
			skip_ws();
			if (*p != ':') {
				fail("expect :");
				return nullptr;
			}
			p++;
			JsonPtr v = value();
			if (!v) return nullptr;
			j->obj.emplace_back(key, v);
			skip_ws();
			if (*p == ',') {
				p++;
				continue;
			}
			if (*p == '}') {
				p++;
				return j;
			}
			fail("expect , or }");
			return nullptr;
		}
		fail("unterminated object");
		return nullptr;
	}

	JsonPtr array() {
		p++; // [
		auto j = Json::make(Json::ARR);
		skip_ws();
		if (p < end && *p == ']') {
			p++;
			return j;
		}
		while (p < end) {
			JsonPtr v = value();
			if (!v) return nullptr;
			j->arr.push_back(v);
			skip_ws();
			if (*p == ',') {
				p++;
				continue;
			}
			if (*p == ']') {
				p++;
				return j;
			}
			fail("expect , or ]");
			return nullptr;
		}
		fail("unterminated array");
		return nullptr;
	}

	bool string_lit(std::string &out) {
		p++; // "
		while (p < end) {
			char c = *p++;
			if (c == '"') return true;
			if (c == '\\') {
				if (p >= end) break;
				char e = *p++;
				switch (e) {
					case '"': out += '"'; break;
					case '\\': out += '\\'; break;
					case '/': out += '/'; break;
					case 'n': out += '\n'; break;
					case 'r': out += '\r'; break;
					case 't': out += '\t'; break;
					case 'b': out += '\b'; break;
					case 'f': out += '\f'; break;
					case 'u': {
						if (end - p < 4) {
							fail("bad \\u");
							return false;
						}
						unsigned code = 0;
						for (int i = 0; i < 4; i++) {
							char h = *p++;
							code <<= 4;
							if (h >= '0' && h <= '9') code |= (unsigned)(h - '0');
							else if (h >= 'a' && h <= 'f') code |= (unsigned)(h - 'a' + 10);
							else if (h >= 'A' && h <= 'F') code |= (unsigned)(h - 'A' + 10);
							else {
								fail("bad hex");
								return false;
							}
						}
						// 只保 BMP 兼容子集（本插件不用非 ASCII 键）→ UTF-8 直出
						if (code < 0x80) out += (char)code;
						else if (code < 0x800) {
							out += (char)(0xC0 | (code >> 6));
							out += (char)(0x80 | (code & 0x3F));
						} else {
							out += (char)(0xE0 | (code >> 12));
							out += (char)(0x80 | ((code >> 6) & 0x3F));
							out += (char)(0x80 | (code & 0x3F));
						}
						break;
					}
					default:
						fail("bad escape");
						return false;
				}
			} else
				out += c;
		}
		fail("unterminated string");
		return false;
	}

	JsonPtr number() {
		char *endp = nullptr;
		double v = std::strtod(p, &endp);
		if (endp == p) {
			fail("bad number");
			return nullptr;
		}
		p = endp;
		return Json::num_of(v);
	}
};
} // namespace

JsonPtr Json::parse(const std::string &text, std::string *err_out) {
	Parser ps;
	ps.p = text.c_str();
	ps.end = text.c_str() + text.size();
	JsonPtr v = ps.value();
	if (!v || err_out != nullptr) {
		if (err_out != nullptr) *err_out = ps.err.empty() ? (v ? "" : "parse failed") : ps.err;
	}
	if (v) {
		ps.skip_ws();
		if (ps.p != ps.end) {
			if (err_out != nullptr) *err_out = "trailing characters";
			return nullptr;
		}
	}
	return v;
}

} // namespace rl
