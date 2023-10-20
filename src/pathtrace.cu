#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#define ERRORCHECK 1
#define SORT_BY_MATERIAL 0
#define CACHE_FIRST_BOUNCE 0
#define ANTI_ALIASING 0
#define DEPTH_OF_FIELD 0
#define PROCEDURAL_TEXTURE 0
#define BVH 1
#define OIDN 0

#if ANTI_ALIASING
#undef CACHE_FIRST_BOUNCE
#define CACHE_FIRST_BOUNCE 0
#endif // ANTI_ALIASING
#if DEPTH_OF_FIELD
#undef CACHE_FIRST_BOUNCE
#define CACHE_FIRST_BOUNCE 0
#endif // DEPTH_OF_FIELD
#if OIDN
#define EMA_ALPHA 0.2f
#define DENOISE_INTERVAL 50
#endif // OIDN

#define OCTENC 0
#define ZBUF 0
// CHECKITOUT - a simple struct for storing scene geometry information per-pixel.
// What information might be helpful for guiding a denoising filter?
struct GBufferPixel {
#if OCTENC
    glm::vec2 oct;
#else
    glm::vec3 normal;
#endif // OCTENC
#if ZBUF
    float z;
#else
    glm::vec3 position;
#endif // ZBUF
};

#if OCTENC
__device__
inline glm::vec2 signNotZero(glm::vec2 v)
{
	return glm::vec2((v.x >= 0.f) ? +1.f : -1.f, (v.y >= 0.f) ? +1.f : -1.f);
}
__device__
inline glm::vec2 float32x3_to_oct(glm::vec3 v)
{
	glm::vec2 p = glm::vec2(v) * (1.f / (fabsf(v.x) + fabsf(v.y) + fabsf(v.z)));
	return (v.z <= 0.f) ? (1.f - glm::abs(glm::vec2(v.y, v.x))) * signNotZero(p) : p;
}
__device__
inline glm::vec3 oct_to_float32x3(glm::vec2 e)
{
	glm::vec3 v = glm::vec3(e.x, e.y, 1.f - fabsf(e.x) - fabsf(e.y));
	if (v.z < 0.f)
	{
		glm::vec2 sign = signNotZero(glm::vec2(v));
		v.x = sign.x * (1.f - fabsf(v.y));
		v.y = sign.y * (1.f - fabsf(v.x));
	}
	return glm::normalize(v);
}
#endif // OCTENC
#if ZBUF
__device__
inline glm::vec3 z_to_pos(Camera& cam, int x, int y, float z)
{
	Ray r;
	r.origin = cam.position;
	r.direction = glm::normalize(cam.view
		- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
		- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
	);
	return getPointOnRay(r, z);
}
#endif // ZBUF


#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

// Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4 *pbo, glm::ivec2 resolution,
							   int iter, glm::vec3 *image)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y)
	{
		int index = x + (y * resolution.x);

		glm::ivec3 color = glm::clamp(
			image[index] * 255.0f / (float)iter,
			glm::vec3(0.0f), glm::vec3(255.0f));

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
		pbo[index].w = 0;
	}
}

__global__ void gbufferToPBO(uchar4* pbo, Camera cam, GBufferPixel* gBuffer, bool showPosition) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < cam.resolution.x && y < cam.resolution.y) {
        int index = x + (y * cam.resolution.x);

		glm::ivec3 color;
		if (showPosition)
		{
			// cornell box
			glm::vec3 minBound(-6, -1, -1), maxBound(6, 11, 11);
#if ZBUF
			color = glm::clamp(z_to_pos(cam, x, y, gBuffer[index].z) - minBound,
				glm::vec3(), (maxBound - minBound)) / (maxBound - minBound) * 255.f;
#else
			color = glm::clamp(gBuffer[index].position - minBound,
				glm::vec3(), (maxBound - minBound)) / (maxBound - minBound) * 255.f;
#endif // ZBUF
		}
		else
		{
#if OCTENC
			color = (glm::vec3(oct_to_float32x3(gBuffer[index].oct)) + 1.f) * .5f * 255.f;
#else
			color = (gBuffer[index].normal + 1.f) * .5f * 255.f;
#endif // OCTENC
		}

        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
        pbo[index].w = 0;
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static GBufferPixel* dev_gBuffer = NULL;
// TODO: static variables for device memory, any extra info you need, etc
// ...
#if CACHE_FIRST_BOUNCE
static ShadeableIntersection* dev_first_bounce_intersections = NULL;
#endif // CACHE_FIRST_BOUNCE

static glm::vec3* dev_vertices = NULL;
static glm::vec3* dev_normals = NULL;
static glm::vec2* dev_texcoords = NULL;
static Mesh* dev_meshes = NULL;

#if BVH
static BVHNode* dev_bvh = NULL;
#endif // BVH

#if OIDN
#include "OpenImageDenoise/oidn.hpp"

static glm::vec3* dev_denoised = NULL;
static glm::vec3* dev_albedo = NULL;
static glm::vec3* dev_normal = NULL;

void denoise()
{
	int width = hst_scene->state.camera.resolution.x,
		height = hst_scene->state.camera.resolution.y;

	// Create an Intel Open Image Denoise device
    oidn::DeviceRef device = oidn::newDevice();
    device.commit();

    // Create buffers for input/output images accessible by both host (CPU) and device (CPU/GPU)
	// oidn::BufferRef colorBuf = device.newBuffer(width * height * sizeof(glm::vec3));
	// oidn::BufferRef albedoBuf = device.newBuffer(width * height * sizeof(glm::vec3));
	// oidn::BufferRef normalBuf = device.newBuffer(width * height * sizeof(glm::vec3));

    // Create a filter for denoising a beauty (color) image using prefiltered auxiliary images too
    oidn::FilterRef filter = device.newFilter("RT"); // generic ray tracing filter
    filter.setImage("color", dev_image, oidn::Format::Float3, width, height); // beauty
	filter.setImage("albedo", dev_albedo, oidn::Format::Float3, width, height); // auxiliary
	filter.setImage("normal", dev_normal, oidn::Format::Float3, width, height); // auxiliary
    filter.setImage("output", dev_denoised, oidn::Format::Float3, width, height); // denoised beauty
    filter.set("hdr", true); // image is HDR
	filter.set("cleanAux", true); // auxiliary images will be prefiltered
    filter.commit();

	// Copy the rendered image to the color buffer
	// cudaMemcpy(colorBuf.getData(), dev_image, width * height * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	// cudaMemcpy(albedoBuf.getData(), dev_albedo, width * height * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	// cudaMemcpy(normalBuf.getData(), dev_normal, width * height * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	// cudaDeviceSynchronize();

	// Create a separate filter for denoising an auxiliary albedo image (in-place)
	oidn::FilterRef albedoFilter = device.newFilter("RT"); // same filter type as for beauty
	albedoFilter.setImage("albedo", dev_albedo, oidn::Format::Float3, width, height);
	albedoFilter.setImage("output", dev_albedo, oidn::Format::Float3, width, height);
	albedoFilter.commit();

	// Create a separate filter for denoising an auxiliary normal image (in-place)
	oidn::FilterRef normalFilter = device.newFilter("RT"); // same filter type as for beauty
	normalFilter.setImage("normal", dev_normal, oidn::Format::Float3, width, height);
	normalFilter.setImage("output", dev_normal, oidn::Format::Float3, width, height);
	normalFilter.commit();

	// Prefilter the auxiliary images
	albedoFilter.execute();
	normalFilter.execute();

	// Filter the beauty image
	filter.execute();

	// Check for errors
	const char* errorMessage;
	if (device.getError(errorMessage) != oidn::Error::None)
		std::cout << "Error: " << errorMessage << std::endl;
}

__global__
void copyFirstTraceToAlbedoAndNormal(
	PathSegment *pathSegments, int num_paths,
	ShadeableIntersection *shadeableIntersections,
	glm::vec3 *albedo, glm::vec3 *normal)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths) {
		PathSegment pathSegment = pathSegments[idx];
		ShadeableIntersection intersection = shadeableIntersections[idx];

		albedo[pathSegment.pixelIndex] = pathSegment.color;
		normal[pathSegment.pixelIndex] = intersection.surfaceNormal;
	}
}

__global__
void emaMergeDenoisedAndImage(int pixelcount, glm::vec3 *image, glm::vec3 *denoised)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < pixelcount) {
		// exponential moving average
		image[idx] = image[idx] * (1 - EMA_ALPHA) + denoised[idx] * EMA_ALPHA;
	}
}
#endif // OIDN


static glm::vec3* dev_denoised1 = NULL;
static glm::vec3* dev_denoised2 = NULL;

__constant__ float kernel[25] = {
    1/256.f, 1/64.f, 3/128.f, 1/64.f, 1/256.f,
    1/ 64.f, 1/16.f, 3/ 32.f, 1/16.f, 1/ 64.f,
    3/128.f, 3/32.f, 9/ 64.f, 3/32.f, 3/128.f,
    1/ 64.f, 1/16.f, 3/ 32.f, 1/16.f, 1/ 64.f,
    1/256.f, 1/64.f, 3/128.f, 1/64.f, 1/256.f,
};

__constant__ char2 offset[25] = {
    {-2, -2}, {-2, -1}, {-2, 0}, {-2, 1}, {-2, 2},
    {-1, -2}, {-1, -1}, {-1, 0}, {-1, 1}, {-1, 2},
    { 0, -2}, { 0, -1}, { 0, 0}, { 0, 1}, { 0, 2},
    { 1, -2}, { 1, -1}, { 1, 0}, { 1, 1}, { 1, 2},
    { 2, -2}, { 2, -1}, { 2, 0}, { 2, 1}, { 2, 2},
};

__global__ void kernDenoise(
	Camera cam,
	int iter, glm::vec3* image,
	GBufferPixel* gBuffer,
	int stepwidth, float c_phi, float n_phi, float p_phi,
	glm::vec3* denoised)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y)
	{
        int index = x + (y * cam.resolution.x);
		glm::vec3 sum{0.f};

		glm::vec3 cval = image[index];
#if OCTENC
		glm::vec3 nval = oct_to_float32x3(gBuffer[index].oct);
#else
		glm::vec3 nval = gBuffer[index].normal;
#endif // OCTENC
#if ZBUF
		glm::vec3 pval = z_to_pos(cam, x, y, gBuffer[index].z);
#else
		glm::vec3 pval = gBuffer[index].position;
#endif // ZBUF

		float cum_w = 0.f;
		for (int i = 0; i < 25; i++)
		{
			int uv = index + (offset[i].x + offset[i].y * cam.resolution.x) * stepwidth;
			if (uv < 0 || uv >= cam.resolution.x * cam.resolution.y) continue;

			glm::vec3 ctmp = image[uv];
			float c_w = fminf(__expf(-__fdividef(glm::length2((cval - ctmp) / (float)iter), c_phi)), 1.f);

#if OCTENC
			glm::vec3 ntmp = oct_to_float32x3(gBuffer[uv].oct);
#else
			glm::vec3 ntmp = gBuffer[uv].normal;
#endif // OCTENC
			float n_w = fminf(__expf(-__fdividef(glm::length2(nval - ntmp), n_phi)), 1.f);

#if ZBUF
			glm::vec3 ptmp = z_to_pos(cam, x, y, gBuffer[uv].z);
#else
			glm::vec3 ptmp = gBuffer[uv].position;
#endif // ZBUF
			float p_w = fminf(__expf(-__fdividef(glm::length2(pval - ptmp), p_phi)), 1.f);

			float weight = c_w * n_w * p_w;
			// float weight = 1.f; // without weight
			sum += ctmp * weight * kernel[i];
			cum_w += weight * kernel[i];
		}
		denoised[index] = sum / cum_w;
	}
}


void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));
	cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	// TODO: initialize any extra device memeory you need
#if CACHE_FIRST_BOUNCE
	cudaMalloc(&dev_first_bounce_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_first_bounce_intersections, 0, pixelcount * sizeof(ShadeableIntersection));
#endif // CACHE_FIRST_BOUNCE

	cudaMalloc(&dev_vertices, scene->vertices.size() * sizeof(glm::vec3));
	cudaMemcpy(dev_vertices, scene->vertices.data(), scene->vertices.size() * sizeof(glm::vec3), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_normals, scene->normals.size() * sizeof(glm::vec3));
	cudaMemcpy(dev_normals, scene->normals.data(), scene->normals.size() * sizeof(glm::vec3), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_texcoords, scene->texcoords.size() * sizeof(glm::vec2));
	cudaMemcpy(dev_texcoords, scene->texcoords.data(), scene->texcoords.size() * sizeof(glm::vec2), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_meshes, scene->meshes.size() * sizeof(Mesh));
	cudaMemcpy(dev_meshes, scene->meshes.data(), scene->meshes.size() * sizeof(Mesh), cudaMemcpyHostToDevice);

#if BVH
	cudaMalloc(&dev_bvh, scene->bvh.size() * sizeof(BVHNode));
	cudaMemcpy(dev_bvh, scene->bvh.data(), scene->bvh.size() * sizeof(BVHNode), cudaMemcpyHostToDevice);
#endif // BVH

#if OIDN
	cudaMalloc(&dev_denoised, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_denoised, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_albedo, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_albedo, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_normal, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_normal, 0, pixelcount * sizeof(glm::vec3));
#endif // OIDN

	cudaMalloc(&dev_denoised1, pixelcount * sizeof(glm::vec3));
	cudaMalloc(&dev_denoised2, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_denoised1, 0, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_denoised2, 0, pixelcount * sizeof(glm::vec3));

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
    cudaFree(dev_gBuffer);
    // TODO: clean up any extra device memory you created

#if CACHE_FIRST_BOUNCE
	cudaFree(dev_first_bounce_intersections);
#endif // CACHE_FIRST_BOUNCE

	cudaFree(dev_vertices);
	cudaFree(dev_normals);
	cudaFree(dev_texcoords);
	cudaFree(dev_meshes);

#if BVH
	cudaFree(dev_bvh);
#endif // BVH

#if OIDN
	cudaFree(dev_denoised);
	cudaFree(dev_albedo);
	cudaFree(dev_normal);
#endif // OIDN

	cudaFree(dev_denoised1);
	cudaFree(dev_denoised2);

	checkCUDAError("pathtraceFree");
}

#if DEPTH_OF_FIELD
__host__ __device__
glm::vec2 ConcentricSampleDisk(const glm::vec2& u)
{
	glm::vec2 uOffset = 2.0f * u - glm::vec2(1.0f, 1.0f);

	if (uOffset.x == 0.0f && uOffset.y == 0.0f)
	{
		return glm::vec2(0.0f, 0.0f);
	}

	float theta, r;
	if (glm::abs(uOffset.x) > glm::abs(uOffset.y))
	{
		r = uOffset.x;
		theta = PI_OVER_FOUR * (uOffset.y / uOffset.x);
	}
	else
	{
		r = uOffset.y;
		theta = PI_OVER_TWO - PI_OVER_FOUR * (uOffset.x / uOffset.y);
	}
	return r * glm::vec2(glm::cos(theta), glm::sin(theta));
}
#endif // DEPTH_OF_FIELD

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__
void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	// locate (x, y) in pixel space
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	// make sure (x, y) is not out of bounds
	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);
#if ANTI_ALIASING
		// implement antialiasing by jittering the ray
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x + u01(rng) - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y + u01(rng) - (float)cam.resolution.y * 0.5f)
		);
#else
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
#endif // ANTI_ALIASING
#if DEPTH_OF_FIELD
		if (cam.lensRadius > 0)
		{
			glm::vec2 pLens = cam.lensRadius * ConcentricSampleDisk(glm::vec2(u01(rng), u01(rng)));
			float ft = cam.focalDistance / glm::dot(cam.view, segment.ray.direction);
			glm::vec3 pFocus = segment.ray.origin + segment.ray.direction * ft;
			segment.ray.origin += cam.right * pLens.x + cam.up * pLens.y;
			segment.ray.direction = glm::normalize(pFocus - segment.ray.origin);
		}
#endif // DEPTH_OF_FIELD

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__
void computeIntersections(
	int depth,
	PathSegment* pathSegments,
	int num_paths,
	Geom* geoms,
	int geoms_size,
#if BVH
	BVHNode* bvh,
#endif // BVH
	Mesh* meshes,
	glm::vec3* vertices,
	glm::vec3* normals,
	glm::vec2* texcoords,
	ShadeableIntersection* intersections)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		glm::vec2 texcoord;
		float t_min = FLT_MAX;
		int hit_material_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		int tmp_material_index;
		glm::vec3 tmp_normal;
		glm::vec2 tmp_texcoord;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				tmp_material_index = geom.materialid;
				tmp_normal = outside ? tmp_normal : -tmp_normal;
				tmp_texcoord = glm::vec2(-1.f);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				tmp_material_index = geom.materialid;
				tmp_normal = outside ? tmp_normal : -tmp_normal;
				tmp_texcoord = glm::vec2(-1.f);
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?
			else if (geom.type == MESH)
			{
#if BVH
				t = meshIntersectionTestBVH(
					geom,
					bvh,
					meshes, vertices, normals, texcoords,
					pathSegment.ray,
					tmp_intersect, tmp_material_index, tmp_normal, tmp_texcoord);
#else
				t = meshIntersectionTest(
					geom,
					meshes, vertices, normals, texcoords,
					pathSegment.ray,
					tmp_intersect, tmp_material_index, tmp_normal, tmp_texcoord);
#endif // BVH
			}

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_material_index = tmp_material_index;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
				texcoord = tmp_texcoord;
			}
		}

		if (hit_material_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = hit_material_index;
			intersections[path_index].surfaceNormal = normal;
			intersections[path_index].texcoord = texcoord;
		}
	}
}

__global__
void shadePhysicallyBasedMaterial(
	int iter,
	int num_paths,
	ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
	Material* materials)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths) {
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) {
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);

			Material material = materials[intersection.materialId];

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (material.albedo * material.emittance);
				pathSegments[idx].remainingBounces = 0;
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				if (intersection.texcoord.x >= 0.f && intersection.texcoord.x <= 1.f &&
					intersection.texcoord.y >= 0.f && intersection.texcoord.y <= 1.f)
				{
					switch (PROCEDURAL_TEXTURE)
					{
					case 0:
						break;

					case 1:
						material.albedo = ProceduralTexture::palettes(intersection.texcoord);
						break;

					case 2:
						material.albedo = ProceduralTexture::checkerboard(intersection.texcoord);
						break;

					case 3:
						material.albedo = ProceduralTexture::random(intersection.texcoord);
						break;

					default:
						break;
					}
				}
				scatterRay(pathSegments[idx], getPointOnRay(pathSegments[idx].ray, intersection.t),
					intersection.surfaceNormal, material, rng);
				if (pathSegments[idx].remainingBounces == 0) pathSegments[idx].color = glm::vec3(0.0f);
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		} else {
			pathSegments[idx].color = glm::vec3(0.0f);
			pathSegments[idx].remainingBounces = 0;
		}
	}
}

__global__ void generateGBuffer(
	int num_paths,
	ShadeableIntersection *shadeableIntersections,
	PathSegment *pathSegments,
	GBufferPixel *gBuffer)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
#if OCTENC
		gBuffer[idx].oct = float32x3_to_oct(shadeableIntersections[idx].surfaceNormal);
#else
		gBuffer[idx].normal = shadeableIntersections[idx].surfaceNormal;
#endif // OCTENC
#if ZBUF
		gBuffer[idx].z = shadeableIntersections[idx].t;
#else
		gBuffer[idx].position = getPointOnRay(pathSegments[idx].ray, shadeableIntersections[idx].t);
#endif // ZBUF
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

// Predicate for stream compaction
struct gtZero
{
	__host__ __device__
	bool operator()(const PathSegment &x)
	{
		return x.remainingBounces > 0;
	}
};

struct compareMaterialId
{
	__host__ __device__
	bool operator()(const ShadeableIntersection &x, const ShadeableIntersection &y)
	{
		return x.materialId < y.materialId;
	}
};

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera<<<blocksPerGrid2d, blockSize2d>>>(cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	// Empty gbuffer
	// cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	// clean shading chunks
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	bool iterationComplete = false;
	while (!iterationComplete) {
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
#if CACHE_FIRST_BOUNCE
		if (depth == 0 && iter > 1)
		{
			cudaMemcpy(dev_intersections, dev_first_bounce_intersections,
					   pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			checkCUDAError("copy first bounce");
		}
		else
		{
			// tracing
			computeIntersections<<<numblocksPathSegmentTracing, blockSize1d>>>(
				depth,
				dev_paths, num_paths,
				dev_geoms, hst_scene->geoms.size(),
#if BVH
				dev_bvh,
#endif // BVH
				dev_meshes, dev_vertices, dev_normals, dev_texcoords,
				dev_intersections);
			// cache first bounce
			if (depth == 0 && iter == 1)
			{
				cudaMemcpy(dev_first_bounce_intersections, dev_intersections,
						   pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
			}
			checkCUDAError("trace one bounce");
		}
		cudaDeviceSynchronize();
#else
		// tracing
		computeIntersections<<<numblocksPathSegmentTracing, blockSize1d>>>(
			depth,
			dev_paths, num_paths,
			dev_geoms, hst_scene->geoms.size(),
#if BVH
			dev_bvh,
#endif // BVH
			dev_meshes, dev_vertices, dev_normals, dev_texcoords,
			dev_intersections);
#endif // CACHE_FIRST_BOUNCE
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();

		if (depth == 0 && iter == 1) {
			generateGBuffer<<<numblocksPathSegmentTracing, blockSize1d>>>(num_paths, dev_intersections, dev_paths, dev_gBuffer);
		}

		depth++;

#if SORT_BY_MATERIAL
		// sort paths by material
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, compareMaterialId());
#endif // SORT_BY_MATERIAL

		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// TODO: compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.
		shadePhysicallyBasedMaterial<<<numblocksPathSegmentTracing, blockSize1d>>>(
			iter, num_paths, dev_intersections, dev_paths, dev_materials);

#if OIDN
		// copy image to albedo and normal
		if (depth == 1 && (iter % DENOISE_INTERVAL == 0 || iter == hst_scene->state.iterations))
			copyFirstTraceToAlbedoAndNormal<<<numblocksPathSegmentTracing, blockSize1d>>>(
				dev_paths, num_paths, dev_intersections, dev_albedo, dev_normal);
#endif // OIDN

		// iterationComplete = true; // TODO: should be based off stream compaction results.
		dev_path_end = thrust::partition(thrust::device, dev_paths, dev_paths + num_paths, gtZero());
		num_paths = dev_path_end - dev_paths;
		iterationComplete = num_paths == 0;
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather<<<numBlocksPixels, blockSize1d>>>(pixelcount, dev_image, dev_paths);

#if OIDN
	if (iter % DENOISE_INTERVAL == 0)
	{
		denoise();
		emaMergeDenoisedAndImage<<<numBlocksPixels, blockSize1d>>>(pixelcount, dev_image, dev_denoised);
	}
	else if (iter == hst_scene->state.iterations)
    {
		denoise();
        std::swap(dev_image, dev_denoised);
    }
#endif // OIDN

	///////////////////////////////////////////////////////////////////////////

    // CHECKITOUT: use dev_image as reference if you want to implement saving denoised images.
    // Otherwise, screenshots are also acceptable.
    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

// CHECKITOUT: this kernel "post-processes" the gbuffer/gbuffers into something that you can visualize for debugging.
void showGBuffer(uchar4* pbo, bool showPosition) {
    const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // CHECKITOUT: process the gbuffer results and send them to OpenGL buffer for visualization
    gbufferToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam, dev_gBuffer, showPosition);
}

void showDenoised(
	uchar4* pbo,
	int filter_size, float c_phi, float n_phi, float p_phi, int iter)
{
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	cudaMemcpy(dev_denoised1, dev_image, pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToDevice);

	int stepwidth = 1;
	for (int stepwidth = 1; stepwidth * 5 <= filter_size; stepwidth <<= 1)
	{
		// Denoise
		kernDenoise<<<blocksPerGrid2d, blockSize2d>>>(
			cam,
			iter, dev_denoised1,
			dev_gBuffer, stepwidth, c_phi, n_phi, p_phi,
			dev_denoised2);
		std::swap(dev_denoised1, dev_denoised2);
	}

	// Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_denoised1);
}

void showImage(uchar4* pbo, int iter) {
	const Camera &cam = hst_scene->state.camera;
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_image);
}
