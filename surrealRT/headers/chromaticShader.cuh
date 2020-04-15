#pragma once
#include <Windows.h>

#include "vec3.cuh"

struct color {
	BYTE b, g, r;
};

struct shaderMask {
	bool camCoord;//camera coordinates
	bool surfaceNormal;//normal of contact surface
};

struct shaderData {
	vec3d dr;
	vec3d pt;
	vec3s camCoord;
	vec3d surfaceNormal;
};

class chromaticShader {
public:
	shaderMask sm;
	__device__ chromaticShader() {
		sm.camCoord = false;
		sm.surfaceNormal = false;
	}
	__device__ ~chromaticShader(){}
	__device__ virtual color shade(shaderData& sd) { return color{ 0,0,0 }; }
};

class solidColor : public chromaticShader {
public:
	color c;
	__device__ solidColor() { c.r = 0; c.b = 0; c.g = 0; }
	__device__ solidColor(color C) { c = C; }
	__device__ ~solidColor() {}
	__device__ color shade(shaderData& sd) { return c; }
};


class skybox :public chromaticShader {
public:
	color up;
	color down;

	__device__ skybox(color Up, color Down) { up = Up; down = Down; }
	__device__ skybox(){}
	__device__ color shade(shaderData& sd) {
		float ratio = vec3d::dot(sd.dr, vec3d(0, 0, 1))/sd.dr.mag();
		ratio += 1;
		ratio /= 2;
		color rVal;
		rVal.r = up.r * ratio + down.r * (1 - ratio);
		rVal.g = up.g * ratio + down.g * (1 - ratio);
		rVal.b = up.b * ratio + down.b * (1 - ratio);
		return rVal;
	}
};
