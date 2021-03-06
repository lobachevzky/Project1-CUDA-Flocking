#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"
#include <string>

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)
#define DEBUG 0
#define dim 3
#define maxNumGridSearch (dim * dim * dim)
#define gridOOB -1

#if DEBUG
#define debug(...) printf(__VA_ARGS__);
#define debug0(...) if (index == 0) { printf(__VA_ARGS__); }
#define debug4000(...) if (index == 4000) { printf(__VA_ARGS__); }
#else
#define debug(...) {}
#define debug0(...) {}
#define debug4000(...) {}
#endif

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.01f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
glm::vec3 *dev_sortedPos;
glm::vec3 *dev_sortedVel;

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/


__device__ int thread_index() {
    return threadIdx.x + (blockIdx.x * blockDim.x);
}


__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 * arr, float scale) {
  int index = thread_index();
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params
  gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x = 0 - halfGridWidth;
  gridMinimum.y = 0 - halfGridWidth;
  gridMinimum.z = 0 - halfGridWidth;

  //// TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");
  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");
  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");
  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");
  cudaMalloc((void**)&dev_sortedPos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_sortedPos failed!");
  cudaMalloc((void**)&dev_sortedVel, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_sortedVel failed!");
  cudaThreadSynchronize();
}



/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaThreadSynchronize();
}



/******************
* stepSimulation *
******************/


/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int start, int end, 
    int iSelf, const int *particleArrayIndices, const glm::vec3 *pos, const glm::vec3 *vel) {
    glm::vec3 thisPos = pos[iSelf];

    int neighborCount = 0;

    glm::vec3 center(0.0f);
    glm::vec3 separate(0.0f);
    glm::vec3 cohesion(0.0f);

    for (int i = start; i < end; ++i) {
        if (i == iSelf) continue;

        glm::vec3 thatPos = pos[i];

        float distance = glm::length(thatPos - thisPos);

        // Rule 1: Cohesion: boids fly towards the center of mass of neighboring boids
        if (distance < rule1Distance) {
            center += thatPos;
            neighborCount += 1;
        }

        // Rule 2: Separation: boids try to keep a small distance away from each other
        if (distance < rule2Distance) {
            separate -= thatPos - thisPos;
        }

        // Rule 3: Alignment: boids try to match the velocities of neighboring boids
        if (distance < rule3Distance) {
            cohesion += vel[i];
        }
    }

    glm::vec3 toCenter(0.0f);
    if (neighborCount > 0) {
        center /= neighborCount;
        toCenter = (center - thisPos);
    }

    return toCenter * rule1Scale
        + separate * rule2Scale
        + cohesion * rule3Scale;
}

__device__ glm::vec3 computeVelocityChangeInGrids(
    int *gridsToSearch, int *gridStartIndices, int *gridEndIndices,
    int start, int end, int index, const int *indexToBoid, 
    const glm::vec3 *pos, const glm::vec3 *vel) {

    glm::vec3 thisPos = pos[index];

    int neighborCount = 0;

    glm::vec3 center(0.0f);
    glm::vec3 separate(0.0f);
    glm::vec3 cohesion(0.0f);

	int compare = 0;

    for (int j = 0; j < maxNumGridSearch; j++) {
        int grid = gridsToSearch[j];
        if (grid == gridOOB) continue;

        start = gridStartIndices[grid];
        end = gridEndIndices[grid];

        for (int i = start; i < end; i++) {
			compare++;

            int boid = indexToBoid ? indexToBoid[i] : i;
            if (boid == index) continue;

            glm::vec3 thatPos = pos[boid];
            float distance = glm::length(thatPos - thisPos);

            // Rule 1: Cohesion: boids fly towards the center of mass of neighboring boids
            if (distance < rule1Distance) {
                center += thatPos;
                neighborCount += 1;
            }


            // Rule 2: Separation: boids try to keep a small distance away from each other
            if (distance < rule2Distance) {
                separate -= thatPos - thisPos;
            }

            // Rule 3: Alignment: boids try to match the velocities of neighboring boids
            if (distance < rule3Distance) {
                cohesion += vel[boid];
            }
        }
    }

    glm::vec3 toCenter(0.0f);
    if (neighborCount > 0) {
        center /= neighborCount;
        toCenter = (center - thisPos);
    }

    return toCenter * rule1Scale
        + separate * rule2Scale
        + cohesion * rule3Scale;
}

__device__ void updateVelocities(glm::vec3 *vel1, glm::vec3 *vel2, 
  glm::vec3 acceleration, int index) {
      glm::vec3 newVel = vel1[index] + acceleration;
      // - Clamp the speed change before putting the new speed in vel2

      float currentSpeed = glm::length(newVel);
      float speed = fmin(currentSpeed, maxSpeed);

	  glm::vec3 norm = glm::normalize(newVel);
	  if (newVel.x == 0 && newVel.y == 0 && newVel.z == 0) {
		  norm = glm::vec3(0.0);
	  }

      // Record the new velocity into vel2. Question: why NOT vel1?
      vel2[index] = norm * speed;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }

  glm::vec3 acceleration = computeVelocityChange(0, N, index, NULL, pos, vel1);
  updateVelocities(vel1, vel2, acceleration, index);
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  if (x < 0 || x >= gridResolution ||
	  y < 0 || y >= gridResolution ||
	  z < 0 || z >= gridResolution) {
	   return gridOOB;
  }
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__device__ glm::vec3 posToGrid(glm::vec3 pos, glm::vec3 gridMin, float inverseCellWidth, int gridResolution) {
	glm::vec3 grid((pos - gridMin) * inverseCellWidth);
	grid = glm::floor(grid);
	int backOff = gridResolution - 1;
	if ((int)grid.x == gridResolution) grid.x = backOff;
	if ((int)grid.y == gridResolution) grid.y = backOff;
	if ((int)grid.z == gridResolution) grid.z = backOff;
  return grid;
}

__device__ int posToGridIndex(glm::vec3 pos, glm::vec3 gridMin,
	float inverseCellWidth, int gridResolution) {
	glm::vec3 grid = posToGrid(pos, gridMin, inverseCellWidth, gridResolution);
	return gridIndex3Dto1D((int)grid.x, (int)grid.y, (int)grid.z, gridResolution);
}

// gridResolution: number of grids per side
// gridMin: value of most negative point in the grid
__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
    // TODO-2.1
    // - Label each boid with the index of its grid cell.
    int index = thread_index();
    if (index < N) {
        glm::vec3 thisPos = pos[index];
        gridIndices[index] = posToGridIndex(thisPos, gridMin,
            inverseCellWidth, gridResolution);
        indices[index] = index;
    }
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = thread_index();
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void test(int *boidIndices, int *grids, 
    int *gridCellStartIndices, int *gridCellEndIndices) {
    int x = boidIndices[0];
    int y = grids[0];
    int z = gridCellStartIndices[0];
    int w = gridCellEndIndices[0];
    //if (1) {
    //    printf("test");
    //}
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
    // TODO: eliminate branches
    int index = thread_index();
    if (index < N) {
        int thisGrid = particleGridIndices[index];
        if (index == 0) {
          gridCellStartIndices[thisGrid] = 0;
          return;
        }
        int prevGrid = particleGridIndices[index - 1];
        if (index == (N - 1)) {
          gridCellEndIndices[thisGrid] = index;
          if (thisGrid != prevGrid) {
            gridCellStartIndices[thisGrid] = index;
          }
          return;
        }
        if (thisGrid != prevGrid) {
            // "this index doesn't match the one before it, must be a new cell!"
            gridCellStartIndices[thisGrid] = index;
            gridCellEndIndices[prevGrid] = index;
        }
    }
}

__device__ void updateVelNeighborSearch(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  int index = thread_index();
  if (index < N) {
      // - Identify the grid cell that this particle is in
      // - Identify which cells may contain neighbors. This isn't always 8.
      // - For each cell, read the start/end indices in the boid pointer array.
      glm::vec3 thisPos = pos[index];
      glm::vec3 thisGrid = posToGrid(thisPos, gridMin, inverseCellWidth, gridResolution);

      int gridsToSearch[maxNumGridSearch];
      for (int x = -1; x <= 1; x++) {
          for (int y = -1; y <= 1; y++) {
              for (int z = -1; z <= 1; z++) {
				  int grid = gridIndex3Dto1D(
					thisGrid.x + x, thisGrid.y + y, thisGrid.z + z, gridResolution);
				  int n = gridIndex3Dto1D(x + 1, y + 1, z + 1, dim); // map x, y, z to unique int between 1 and maxNumGridSearch
				  gridsToSearch[n] = grid;
              }
          }
      }

      // - Access each boid in the cell and compute velocity change from
      //   the boids rules, if this boid is within the neighborhood distance.
      glm::vec3 acceleration = computeVelocityChangeInGrids(
          gridsToSearch, gridCellStartIndices, gridCellEndIndices,
          0, N, index, particleArrayIndices, pos, vel1);
      updateVelocities(vel1, vel2, acceleration, index);
  }
}


__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
	updateVelNeighborSearch(
		N, gridResolution, gridMin,
		inverseCellWidth, cellWidth,
		gridCellStartIndices, gridCellEndIndices,
		particleArrayIndices, pos, vel1, vel2);
}

__global__ void kernSortPosVel(int *particleArrayIndices, 
	int N, glm::vec3 *sortedPos, glm::vec3 *sortedVel, 
	glm::vec3 *pos, glm::vec3 *vel) {
	int index = thread_index();
  if (index < N) {
    int oldIndex = particleArrayIndices[index];
    sortedPos[index] = pos[oldIndex];
    sortedVel[index] = vel[oldIndex];
	// TODO: sort velocities
  }
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
	updateVelNeighborSearch(
		N, gridResolution, gridMin,
		inverseCellWidth, cellWidth,
		gridCellStartIndices, gridCellEndIndices,
		NULL, pos, vel1, vel2);
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
    dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
    kernUpdateVelocityBruteForce << < fullBlocksPerGrid, threadsPerBlock >> >(numObjects, dev_pos, dev_vel1, dev_vel2);
    kernUpdatePos << < fullBlocksPerGrid, threadsPerBlock >> >(numObjects, dt, dev_pos, dev_vel2);

  // TODO-1.2 ping-pong the velocity buffers
    glm::vec3 *swap = dev_vel1;
    dev_vel1 = dev_vel2;
    dev_vel2 = swap;
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // TODO-2.1
    dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
    kernComputeIndices << <fullBlocksPerGrid, threadsPerBlock >> > (numObjects,
        gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
        dev_particleArrayIndices, dev_particleGridIndices);
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
    

    ///////////////////////
    //#define testN 5
    //int arrayIndices[testN];
    //int gridIndices[testN];
    //glm::vec3 pos[testN];

    //cudaMemcpy(arrayIndices, dev_particleArrayIndices, sizeof(int) * testN, cudaMemcpyDeviceToHost);
    //cudaMemcpy(gridIndices, dev_particleGridIndices, sizeof(int) * testN, cudaMemcpyDeviceToHost);
    //cudaMemcpy(pos, dev_pos, sizeof(int) * testN, cudaMemcpyDeviceToHost);
    //checkCUDAErrorWithLine("memcpy back failed!");

    //std::cout << "before unstable sort: " << std::endl;
    //for (int i = 0; i < testN; i++) {
    //  std::cout << "  arrayIndex: " << arrayIndices[i];
    //  std::cout << " gridIndex: " << gridIndices[i];
    //  std::cout << " pos: " << pos[i].x << " " << pos[i].y << " " << pos[i].z << std::endl;
    //}
    //\\\\\\\\\\\\\\\\\\\\\\\\\

    thrust::device_ptr<int> thrust_particleArrayIndices(dev_particleArrayIndices);
    thrust::device_ptr<int> thrust_particleGridIndices(dev_particleGridIndices);
    thrust::sort_by_key(
        thrust_particleGridIndices,
        thrust_particleGridIndices + numObjects,
        thrust_particleArrayIndices);

    ///////////////////////
    //cudaMemcpy(arrayIndices, dev_particleArrayIndices, sizeof(int) * testN, cudaMemcpyDeviceToHost);
    //cudaMemcpy(gridIndices, dev_particleGridIndices, sizeof(int) * testN, cudaMemcpyDeviceToHost);
    //cudaMemcpy(pos, dev_pos, sizeof(int) * testN, cudaMemcpyDeviceToHost);
    //checkCUDAErrorWithLine("memcpy back failed!");

    //std::cout << "after unstable sort: " << std::endl;
    //for (int i = 0; i < testN; i++) {
    //  std::cout << "  arrayIndex: " << arrayIndices[i];
    //  std::cout << " gridIndex: " << gridIndices[i];
    //  std::cout << " pos: " << pos[i].x << " " << pos[i].y << " " << pos[i].z << std::endl;
    //}
    //\\\\\\\\\\\\\\\\\\\\\\\\\

  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
    dim3 fullGrids((pow(gridSideCount, 3) + blockSize - 1) / blockSize);
    kernResetIntBuffer << <fullGrids, threadsPerBlock >> >(
        numObjects, dev_gridCellStartIndices, -1);
    kernResetIntBuffer << <fullGrids, threadsPerBlock >> >(
        numObjects, dev_gridCellEndIndices, -1);

    kernIdentifyCellStartEnd << <fullBlocksPerGrid, threadsPerBlock >> >(
        numObjects, dev_particleGridIndices,    
        dev_gridCellStartIndices, dev_gridCellEndIndices);
    
  // - Perform velocity updates using neighbor search
    kernUpdateVelNeighborSearchScattered<< <fullBlocksPerGrid, threadsPerBlock >> >( 
        numObjects, gridSideCount, gridMinimum,
        gridInverseCellWidth, gridCellWidth,
        dev_gridCellStartIndices, dev_gridCellEndIndices,
        dev_particleArrayIndices,
        dev_pos, dev_vel1, dev_vel2);
  // - Update positions
    kernUpdatePos << < fullBlocksPerGrid, threadsPerBlock >> >(
        numObjects, dt, dev_pos, dev_vel2);
  // - Ping-pong buffers as needed
    glm::vec3 *swap = dev_vel1;
    dev_vel1 = dev_vel2;
    dev_vel2 = swap;
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
    dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
    kernComputeIndices << <fullBlocksPerGrid, threadsPerBlock >> > (numObjects,
        gridSideCount, gridMinimum, gridInverseCellWidth, dev_pos,
        dev_particleArrayIndices, dev_particleGridIndices);
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.

    thrust::device_ptr<int> thrust_particleArrayIndices(dev_particleArrayIndices);
    thrust::device_ptr<int> thrust_particleGridIndices(dev_particleGridIndices);
    thrust::sort_by_key(
        thrust_particleGridIndices,
        thrust_particleGridIndices + numObjects,
        thrust_particleArrayIndices);

    dim3 fullGrids((pow(gridSideCount, 3) + blockSize - 1) / blockSize);
    kernResetIntBuffer << <fullGrids, threadsPerBlock >> >(
        numObjects, dev_gridCellStartIndices, -1);
    kernResetIntBuffer << <fullGrids, threadsPerBlock >> >(
        numObjects, dev_gridCellEndIndices, -1);

  // - Naively unroll the loop for finding the start and end indices of each
    kernIdentifyCellStartEnd << <fullBlocksPerGrid, threadsPerBlock >> >(
        numObjects, dev_particleGridIndices,    
        dev_gridCellStartIndices, dev_gridCellEndIndices);
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED

	kernSortPosVel << <fullBlocksPerGrid, threadsPerBlock >> >(
		dev_particleArrayIndices, numObjects, dev_sortedPos, dev_sortedVel,
		dev_pos, dev_vel1);

  // - Perform velocity updates using neighbor search
    kernUpdateVelNeighborSearchCoherent<< <fullBlocksPerGrid, threadsPerBlock >> >( 
        numObjects, gridSideCount, gridMinimum,
        gridInverseCellWidth, gridCellWidth,
        dev_gridCellStartIndices, dev_gridCellEndIndices,
        dev_sortedPos, dev_sortedVel, dev_vel2);
  // - Update positions
    kernUpdatePos << < fullBlocksPerGrid, threadsPerBlock >> >(
        numObjects, dt, dev_sortedPos, dev_vel2);
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
    glm::vec3 *swap = dev_pos;
	dev_pos = dev_sortedPos;
	dev_sortedPos = swap;

    swap = dev_vel1;
    dev_vel1 = dev_vel2;
    dev_vel2 = swap;
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
  cudaFree(dev_sortedPos);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  int *intKeys = new int[N];
  int *intValues = new int[N];

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys, sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues, sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys, dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues, dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  delete[] intKeys;
  delete[] intValues;
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}
