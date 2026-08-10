// 程序化材质系统 / 共享 Shader 原语
// 确定性伪随机函数，基于像素坐标 + 种子，每帧输出相同结果
//
// 注意：调用方（stone_lib.gdshaderinc、stone_band/wall/window.gdshader）均以
// 返回值形式调用 `float n = hash21(vec2)`，故此处定义为返回 float 的函数。

#ifndef HASH_GDSHADERINC
#define HASH_GDSHADERINC

// 2D 伪随机，输出 [0, 1]
float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// 3D 伪随机，输出 [0, 1]
float hash31(vec3 p) {
	vec3 p3 = fract(p * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

#endif
