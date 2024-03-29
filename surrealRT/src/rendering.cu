#include "rendering.cuh"

#include <thread>


#ifdef __GPUDEBUG
#include <iostream>
#endif

#define threadNo 1024
#define blockNo(Threads) ((Threads/threadNo) + 1)

__global__
void initRays(short xRes , short yRes , vec3f vertex , vec3f topLeft , vec3f right , vec3f down , linearMath::linef * rays) {
	size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
	if (tId >= (xRes * yRes))return;
	
	short x, short y;
	x = tId % xRes;
	y = tId / xRes;

	rays[tId].setRaw_s(vertex, vec3f::subtract(vec3f::add(topLeft, vec3f::add(vec3f::multiply(right, (x + 0.5) / xRes), vec3f::multiply(down, (y + 0.5) / yRes))), vertex));
}

__device__ __host__ void calculateMeshConstraints(mesh* Mesh , meshConstrained *meshC){
	meshC->a = Mesh->pts[1] - Mesh->pts[0];
	vec3f b = Mesh->pts[2] - Mesh->pts[0];
	vec3f plNormal = vec3f::cross(meshC->a, b);
	meshC->planeNormal = vec3f::normalizeRaw_s(plNormal);
	meshC->sn = vec3f::normalizeRaw_s(vec3f::cross(meshC->planeNormal, meshC->a));

	meshC->coordCalcData.x = vec3f::dot(meshC->sn, b);
	meshC->coordCalcData.y = vec3f::dot(b, meshC->a);
	meshC->coordCalcData.z = meshC->a.mag2();

	if (meshC->coordCalcData.x == 0 || meshC->coordCalcData.z == 0) {
		//do nothing
	}
	else {
		meshC->coordCalcData.x = 1 / meshC->coordCalcData.x;
		meshC->coordCalcData.z = 1 / meshC->coordCalcData.z;
	}

}

__global__
void initMesh(meshShaded* Mesh, meshConstrained* meshC, size_t noOfThreads) {
	size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
	if (tId >= noOfThreads)return;
	calculateMeshConstraints(&((Mesh + tId)->M), meshC + tId);
}

__device__ __host__
void getClosestIntersection(meshShaded * Mesh ,meshConstrained* meshC, size_t noTrs, fragmentProperties &fp) {
	fp.ip.M = nullptr;
	fp.ip.MC = nullptr;
	fp.ip.lambda = -1;
	fp.ip.trId = UINT_MAX;
	double tempDist;
	linearMath::linef ray = (*fp.ray);
	for (size_t i = 0; i < noTrs; ++i) {
		
		
		bool calc = false;
		float dotCalculated = vec3f::dot(ray.getDr(), meshC[i].planeNormal);
		if (Mesh[i].colShader->meshVProp.getBit(meshVisibilityProperties::bitNames::frontVisible)) {
			if (dotCalculated > 0)calc = true;
		}
		if (Mesh[i].colShader->meshVProp.getBit(meshVisibilityProperties::bitNames::backVisible)) {
			if (dotCalculated < 0)calc = true;
		}
		if (calc) {
			tempDist = vec3f::dot(Mesh[i].M.pts[0] - ray.getPt(), meshC[i].planeNormal) / dotCalculated;
		}
		else {
			tempDist = -1;
		}
		


		//check for visibility
		if (tempDist > 0 && (tempDist < fp.ip.lambda || fp.ip.lambda < 0)) {
			//check for inside
			vec3f pt = linearMath::getPt(ray, tempDist);
			vec3f v = pt - Mesh[i].M.pts[0];
			float l1, l2;
			l2 = vec3f::dot(v, meshC[i].sn) * meshC[i].coordCalcData.x;
			l1 = (vec3f::dot(v, meshC[i].a) - l2 * meshC[i].coordCalcData.y) * meshC[i].coordCalcData.z;
			
			//inside
			if (!(l1 > 0))continue;
			if (!(l2 > 0))continue;
			if (Mesh[i].colShader->meshVProp.getBit(meshVisibilityProperties::bitNames::triangle)) {
				if ((l1 + l2 > 1))continue;
			}
			else {
				if ((l1 > 1) || (l2 > 1))continue;
			}
			//write data
			fp.ip.lambda = tempDist;
			fp.ip.pt = pt;
			fp.ip.trId = i;
			fp.ip.cx = l1;
			fp.ip.cy = l2;
		}
	}

	if (fp.ip.trId != UINT_MAX) {
		fp.ip.M = &(Mesh[fp.ip.trId].M);
		fp.ip.MC = meshC + fp.ip.trId;
	}
}


__device__ 
inline fragmentProperties getIntersectionsInternal(linearMath::linef* ray, meshShaded* trs, meshConstrained* collTrs, size_t noTrs, color* pixelData, chromaticShader* defaultShader) {
	fragmentProperties fp;
	fp.ray = ray;
	getClosestIntersection(trs, collTrs, noTrs, fp);

	//shade
	if (fp.ip.trId == UINT_MAX) {
		*pixelData = (defaultShader)->shade(fp);
	}
	else {
		*pixelData = trs[fp.ip.trId].colShader->shade(fp);
	}
	return fp;
}

__global__
void getIntersections(linearMath::linef* rays, size_t noRays, meshShaded* trs, meshConstrained* collTrs, size_t noTrs, color* displayData, chromaticShader* defaultShader) {
	size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
	if (tId >= noRays)return;

	getIntersectionsInternal(rays + tId, trs, collTrs, noTrs, displayData + tId, defaultShader);
}


__global__
void getByteColor(color* data, colorBYTE* dataByte, float min, float delta, size_t noThreads) {
	size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
	if (tId >= noThreads)return;
	color rval = data[tId];
	rval -= vec3f(min, min, min);
	rval *= 256 / delta;
	if (rval.x > 255)dataByte[tId].r = 255;
	else if (rval.x < 0)dataByte[tId].r = 0;
	else dataByte[tId].r = (unsigned char)rval.x;
	if (rval.y > 255)dataByte[tId].g = 255;
	else if (rval.y < 0)dataByte[tId].g = 0;
	else dataByte[tId].g = (unsigned char)rval.y;
	if (rval.z > 255)dataByte[tId].b = 255;
	else if (rval.z < 0)dataByte[tId].b = 0;
	else dataByte[tId].b = (unsigned char)rval.z;
}

void displayCudaError(size_t id = 0) {
#ifdef __GPUDEBUG
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	std::cout << "#" << id <<"  "<< cudaGetErrorName(err)<< std::endl;
	if (err != cudaError::cudaSuccess) {
		int x;
		std::cin >> x;
	}
#else

#endif
}

void generateGPUDisplatData(colorBYTE** data , camera cam) {
	displayCudaError(11);
	cudaMalloc(data, sizeof(colorBYTE) * cam.sc.resX * cam.sc.resY);
	displayCudaError(10);
}

void renderIntermediate(camera cam,colorBYTE* DataByte, meshShaded* meshS, meshConstrained* meshC, size_t noTrs) {
	displayCudaError(9);
	linearMath::linef* rays;
	displayCudaError(8);
	cudaMalloc(&rays, sizeof(linearMath::linef) * cam.sc.resX * cam.sc.resY);
	displayCudaError(7);
	initRays << <blockNo(cam.sc.resX * cam.sc.resY), threadNo >> > (cam.sc.resX, cam.sc.resY, cam.vertex, cam.sc.screenCenter - cam.sc.halfRight + cam.sc.halfUp, cam.sc.halfRight * 2, cam.sc.halfUp * -2, rays);
	displayCudaError(1);
	skyboxCPU defaultShader(color(0, 0, 128), color(-200, -200, -200), color(150, 0, 0), color(0, 0, 64), color(0, 0, 64), color(0, 0, 64));
	//solidColCPU defaultShader(color(0, 0, 0));
	displayCudaError(2);
	color* Data;
	cudaMalloc(&Data, sizeof(color) * cam.sc.resX * cam.sc.resY);
	displayCudaError(3);
	getIntersections << <blockNo(cam.sc.resX * cam.sc.resY), threadNo >> > (rays, cam.sc.resX * cam.sc.resY, meshS, meshC, noTrs, Data, defaultShader.getGPUPtr());
	displayCudaError(4);
	getByteColor << <blockNo(cam.sc.resX * cam.sc.resY), threadNo >> > (Data, DataByte, 0, 256, cam.sc.resX * cam.sc.resY);
	displayCudaError(5);
	cudaFree(Data);
	cudaFree(rays);
	displayCudaError(6);
}

void cpyData(colorBYTE* data , BYTE * displayData, camera cam) {
	cudaDeviceSynchronize();
	displayCudaError(12);
	cudaMemcpy(displayData, data, sizeof(colorBYTE) * cam.sc.resX * cam.sc.resY, cudaMemcpyKind::cudaMemcpyDeviceToHost);
	displayCudaError(13);
	cudaFree(data);
	displayCudaError(14);
}

void Render(camera cam,BYTE *data, meshShaded * meshS , meshConstrained * meshC , size_t noTrs) {
	colorBYTE* displayData;
	generateGPUDisplatData(&displayData, cam);
	renderIntermediate(cam, displayData, meshS, meshC, noTrs);
	cpyData(displayData, data, cam);
}


void graphicalWorld::render(camera cam, BYTE* data) {


	bool updated=false;
	meshShaded* devPtr = meshS->getDevice(&updated);
	if(updated){
		initMesh<<<blockNo(meshS->getNoElements()),threadNo>>>(devPtr, meshC->getDevice(), meshS->getNoElements());
	}
	Render(cam, data, meshS->getDevice(), meshC->getDevice(), meshS->getNoElements());

}

void graphicalWorld::render(camera cam, BYTE* data, std::function<void()> drawCall) {
	std::thread draw(drawCall);
	renderPartial(cam);
	draw.join();
	copyData(cam, data);
}

void graphicalWorld::renderPartial(camera cam) {
	
	bool updated = false;
	meshShaded* devPtr = meshS->getDevice(&updated);
	if (updated) {
		initMesh << <blockNo(meshS->getNoElements()), threadNo >> > (devPtr, meshC->getDevice(), meshS->getNoElements());
	}
	if (tempData != nullptr) {
		cudaDeviceSynchronize();
		cudaFree(tempData);
		tempData = nullptr;
		displayCudaError(16);
	}
	generateGPUDisplatData(&tempData, cam);
	renderIntermediate(cam, tempData, meshS->getDevice(), meshC->getDevice(), meshS->getNoElements());
	//Render(cam, data, meshS->getDevice(), meshC->getDevice(), meshS->getNoElements());
}

void graphicalWorld::copyData(camera cam, BYTE* data) {
	if (tempData != nullptr) {
		cpyData(tempData, data, cam);
		tempData = nullptr;
	}
}



///ADV GRAPHICS WORLD CUDA_functions

namespace ADVRTX {

	__global__
	void initRays(short xResReq,size_t noRays,float xResINV, float yResINV, vec3f vertex, vec3f topLeft, vec3f right, vec3f down, linearMath::linef* rays) {
		size_t tId = threadIdx.x + blockIdx.x * blockDim.x;

		if (tId >= (noRays))return;

		short x, short y;
		x = tId % xResReq;
		y = tId / xResReq;

		rays[tId].setRaw_s(vertex, vec3f::subtract(vec3f::add(topLeft, vec3f::add(vec3f::multiply(right, (x + 0.5) * xResINV), vec3f::multiply(down, (y + 0.5) * yResINV))), vertex));
	}


	//get intersections only for rays on grid points
	//rays ptr to all rays
	//noGPts no of grid points include extra ones
	//xbatch , x separation between grid points , includeing extra x pt
	//ybatch , y separation between two grid pts(including the 1 extra pt) * image width
	__global__
	void getIntersections(linearMath::linef* rays, size_t noGPts,unsigned short noXGridPts, unsigned short xBatch , unsigned short yBatch, meshShaded* trs, meshConstrained* collTrs, size_t noTrs, color* displayData, chromaticShader* defaultShader,graphicalWorldADV::rayMeshData * trackingData) {
		size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
		if (tId >= noGPts)return;

		unsigned short xCoord = tId % noXGridPts;
		unsigned short yCoord = tId / noXGridPts;

		tId = xCoord * xBatch + yCoord * yBatch;

		trackingData[tId].id = getIntersectionsInternal(rays + tId, trs, collTrs, noTrs, displayData + tId, defaultShader).ip.trId;
		
	}


	__global__
		void getByteColor(color* data, colorBYTE* dataByte, float min, float delta,unsigned short xRes,unsigned short yRes , unsigned short xReqRes ) {
		size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
		if (tId >= xRes * yRes)return;
		
		size_t baseId = (tId / xRes) * xReqRes + (tId % xRes);
		color rval = data[baseId];
		rval -= vec3f(min, min, min);
		rval *= 256 / delta;

		if (rval.x > 255)dataByte[tId].r = 255;
		else if (rval.x < 0)dataByte[tId].r = 0;
		else dataByte[tId].r = (unsigned char)rval.x;
		if (rval.y > 255)dataByte[tId].g = 255;
		else if (rval.y < 0)dataByte[tId].g = 0;
		else dataByte[tId].g = (unsigned char)rval.y;
		if (rval.z > 255)dataByte[tId].b = 255;
		else if (rval.z < 0)dataByte[tId].b = 0;
		else dataByte[tId].b = (unsigned char)rval.z;
	}


	//current x res do not include the extra grid point at end , y does include that
	//deltaX is half the x batch size
	__global__
		void doubleResX(color* data, graphicalWorldADV::rayMeshData* idData, unsigned short xResReqINTOdeltaY, unsigned short currentXRes, unsigned short currentYRes, short deltaX, linearMath::linef* rays, meshShaded* trs, meshConstrained* collTrs, size_t noTrs, chromaticShader* defaultShader) {
		size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
		if (tId >= currentXRes * currentYRes)return;

		unsigned short x = tId % currentXRes;
		unsigned short y = tId / currentXRes;

		size_t newID = deltaX + x * deltaX * 2 + y * xResReqINTOdeltaY;
		//check for  linearity
		if (idData[newID - deltaX].id == idData[newID + deltaX].id) {
			fragmentProperties fp;
			fp.camX = x;
			fp.camY = y;
			fp.ray = rays + newID;
			fp.ip.trId = idData[newID - deltaX].id;
			if (fp.ip.trId == UINT_MAX) {
				data[newID] = defaultShader->shade(fp);
			}
			else {
				fp.ip.M = &(trs[fp.ip.trId].M);
				fp.ip.MC = collTrs + fp.ip.trId;
				fp.ip.lambda = vec3f::dot(fp.ip.M->pts[0] - fp.ray->getPt(), fp.ip.MC->planeNormal) / vec3f::dot(fp.ray->getDr(), fp.ip.MC->planeNormal);
				fp.ip.pt = fp.ray->getPt() + fp.ip.lambda * fp.ray->getDr();

				if (trs[fp.ip.trId].colShader->shaderMask.localCoord) {
					vec3f v = fp.ip.pt - fp.ip.M->pts[0];
					fp.ip.cy = vec3f::dot(v, fp.ip.MC->sn) * fp.ip.MC->coordCalcData.x;
					fp.ip.cx = (vec3f::dot(v, fp.ip.MC->a) - fp.ip.cy * fp.ip.MC->coordCalcData.y) * fp.ip.MC->coordCalcData.z;
				}
				data[newID] = trs[fp.ip.trId].colShader->shade(fp);
			}
			idData[newID].id = fp.ip.trId;
		}
		else {
			// do full on rtx
			idData[newID].id = getIntersectionsInternal(rays + newID, trs, collTrs, noTrs, data + newID, defaultShader).ip.trId;
		}
	}


	//current y res do not include the extra grid point at end , x does include that
	//deltaY is half the y batch size
	__global__
		void doubleResY(color* data, graphicalWorldADV::rayMeshData* idData, unsigned short xResReqINTOdeltaY, unsigned short currentXRes, unsigned short currentYRes, short deltaX, linearMath::linef* rays, meshShaded* trs, meshConstrained* collTrs, size_t noTrs, chromaticShader* defaultShader) {
		size_t tId = threadIdx.x + blockIdx.x * blockDim.x;
		if (tId >= currentXRes * currentYRes)return;

		unsigned short x = tId % currentXRes;
		unsigned short y = tId / currentXRes;

		size_t newID = x * deltaX + y * xResReqINTOdeltaY * 2 + xResReqINTOdeltaY;
		//check for  linearity
		if (idData[newID - xResReqINTOdeltaY].id == idData[newID + xResReqINTOdeltaY].id) {
			fragmentProperties fp;
			fp.camX = x;
			fp.camY = y;
			fp.ray = rays + newID;
			fp.ip.trId = idData[newID - xResReqINTOdeltaY].id;
			if (fp.ip.trId == UINT_MAX) {
				data[newID] = defaultShader->shade(fp);
			}
			else {
				fp.ip.M = &(trs[fp.ip.trId].M);
				fp.ip.MC = collTrs + fp.ip.trId;
				fp.ip.lambda = vec3f::dot(fp.ip.M->pts[0] - fp.ray->getPt(), fp.ip.MC->planeNormal) / vec3f::dot(fp.ray->getDr(), fp.ip.MC->planeNormal);
				fp.ip.pt = fp.ray->getPt() + fp.ip.lambda * fp.ray->getDr();

				if (trs[fp.ip.trId].colShader->shaderMask.localCoord) {
					vec3f v = fp.ip.pt - fp.ip.M->pts[0];
					fp.ip.cy = vec3f::dot(v, fp.ip.MC->sn) * fp.ip.MC->coordCalcData.x;
					fp.ip.cx = (vec3f::dot(v, fp.ip.MC->a) - fp.ip.cy * fp.ip.MC->coordCalcData.y) * fp.ip.MC->coordCalcData.z;
				}
				data[newID] = trs[fp.ip.trId].colShader->shade(fp);
			}
			//data[newID] = errorColor;
			idData[newID].id = fp.ip.trId;
		}
		else {
			// do full on rtx
			idData[newID].id = getIntersectionsInternal(rays + newID, trs, collTrs, noTrs, data + newID, defaultShader).ip.trId;
		}
	}


}

///ADV GRAPHICS WORLD functions 
graphicalWorldADV::graphicalWorldADV(commonMemory<meshShaded>* meshPtr, unsigned short xResolution, unsigned short yResolution, unsigned char xIters, unsigned char yIters) {
	meshS = meshPtr;
	meshC = new commonMemory<meshConstrained>(meshS->getNoElements(), commonMemType::deviceOnly);
	xDoublingIterations = xIters;
	yDoublingIterations = yIters;
	xRes = xResolution;
	yRes = yResolution;

	//calculate multiplication factor
	mulFacX = 1;
	for (unsigned short i = 0; i < xIters; ++i)mulFacX *= 2;
	mulFacY = 1;
	for (unsigned short i = 0; i < yIters; ++i)mulFacY *= 2;

	unsigned short rSamplesX = (xRes / mulFacX);
	if (xRes % mulFacX != 0) rSamplesX++;
	unsigned short rSamplesY = (yRes / mulFacY);
	if (yRes % mulFacY != 0) rSamplesY++;


	xResReq = rSamplesX * mulFacX + 1;
	yResReq = rSamplesY * mulFacY + 1;

	gridX = rSamplesX + 1;
	gridY = rSamplesY + 1;

#ifdef __GPUDEBUG
	std::cout << "actual res   = " << xRes << " , " << yRes << std::endl;
	std::cout << "required res = " << xResReq << " , " << yResReq << std::endl;
	std::cout << "grid res     = " << gridX << " , " << gridY << std::endl;
	std::cout << "m Factors    = " << mulFacX << " , " << mulFacY << std::endl;
	std::cout << "d iterations = " << xDoublingIterations << " , " << yDoublingIterations << std::endl;
#endif

	cudaMalloc(&redundancyData, sizeof(redundancyData) * xResReq * yResReq);
	cudaMalloc(&rays, sizeof(linearMath::linef) * xResReq * yResReq);
	cudaMalloc(&tempData, sizeof(color) * xResReq * yResReq);
	cudaMalloc(&actualResData, sizeof(colorBYTE) * xRes * yRes);
}

graphicalWorldADV::~graphicalWorldADV() {

	//delete data created
	delete meshC;
	cudaFree(redundancyData);
	cudaFree(rays);
	cudaFree(tempData);
	cudaFree(actualResData);
}


void graphicalWorldADV::render(camera cam, BYTE* data, bool gridOnly) {
	displayCudaError(0);
	//init mesh
	bool updated = false;
	meshShaded* devPtr = meshS->getDevice(&updated);
	if (updated) {
		initMesh << <blockNo(meshS->getNoElements()), threadNo >> > (devPtr, meshC->getDevice(), meshS->getNoElements());
	}
	displayCudaError(1);

	//init rays
	ADVRTX::initRays<<<blockNo(xResReq * yResReq), threadNo >>>(xResReq, xResReq * yResReq, 1.0/xRes, 1.0/yRes, cam.vertex, cam.sc.screenCenter - cam.sc.halfRight + cam.sc.halfUp, cam.sc.halfRight * 2, cam.sc.halfUp * -2, rays);
	skyboxCPU defaultShader(color(0, 0, 128), color(-200, -200, -200), color(150, 0, 0), color(0, 0, 64), color(0, 0, 64), color(0, 0, 64));
	//solidColCPU defaultShader(color(0, 0, 0));
	displayCudaError(2);
	//do rtx
	ADVRTX::getIntersections << <blockNo(gridX * gridY), threadNo >> > (rays, gridX * gridY, gridX, mulFacX, mulFacY * xResReq, meshS->getDevice(), meshC->getDevice(), meshC->getNoElements(), tempData, defaultShader.getGPUPtr() , redundancyData);
	displayCudaError(3);

	//interpolation
	if(!gridOnly){
		unsigned short currentX = gridX - 1;
		unsigned short currentDelta = mulFacX / 2;
		for (unsigned short i = 0; i < xDoublingIterations; i++) {

			ADVRTX::doubleResX << <blockNo(currentX * gridY), threadNo >> > (tempData, redundancyData, xResReq * mulFacY, currentX, gridY, currentDelta, rays, meshS->getDevice(), meshC->getDevice(), meshC->getNoElements(), defaultShader.getGPUPtr());

			displayCudaError(3.5);
			currentX *= 2;
			currentDelta /= 2;
		}

		unsigned short currentY = gridY - 1;
		currentDelta = mulFacY / 2;
		for (unsigned short i = 0; i < yDoublingIterations; i++) {

			ADVRTX::doubleResY << <blockNo(currentY * xResReq), threadNo >> > (tempData, redundancyData, xResReq * currentDelta, xResReq, currentY, 1, rays, meshS->getDevice(), meshC->getDevice(), meshC->getNoElements(), defaultShader.getGPUPtr());

			displayCudaError(3.5);
			currentY *= 2;
			currentDelta /= 2;
		}
	}
	
	ADVRTX::getByteColor<<<blockNo(xRes*yRes), threadNo >>>(tempData, actualResData, 0, 255, xRes, yRes, xResReq);
	displayCudaError(4);
	//copy data
	cudaDeviceSynchronize();
	if (data != nullptr) {
		cudaMemcpy(data, actualResData, sizeof(colorBYTE) * xRes * yRes, cudaMemcpyKind::cudaMemcpyDeviceToHost);
		cudaDeviceSynchronize();
	}
	displayCudaError(5);
}


void graphicalWorldADV::render(camera cam, BYTE* data, std::function<void()> drawCall) {
	std::thread draw(drawCall);
	render(cam, nullptr);
	draw.join();
	if (data != nullptr) {
		cudaMemcpy(data, actualResData, sizeof(colorBYTE) * xRes * yRes, cudaMemcpyKind::cudaMemcpyDeviceToHost);
		cudaDeviceSynchronize();
	}
}