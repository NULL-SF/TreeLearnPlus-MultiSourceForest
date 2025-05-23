#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <curand_kernel.h>

#include "voxel_query_gpu.h"
#include "cuda_utils.h"


__global__ void voxel_query_kernel_stack(int M, int R1, int R2, int R3, int nsample, 
            float radius, int z_range, int y_range, int x_range, const float *new_xyz, 
            const float *xyz, const int *new_coords, const int *point_indices, int *idx) {
    // :param new_coords: (M1 + M2 ..., 4) centers of the ball query
    // :param point_indices: (B, Z, Y, X)
    // output:
    //      idx: (M1 + M2, nsample)
    int pt_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (pt_idx >= M) return;
    
    new_xyz += pt_idx * 3;
    new_coords += pt_idx * 4;
    idx += pt_idx * nsample;

    curandState state;
    curand_init(pt_idx, 0, 0, &state);
    
    float radius2 = radius * radius;
    float new_x = new_xyz[0];
    float new_y = new_xyz[1];
    float new_z = new_xyz[2];

    int batch_idx = new_coords[0];
    int new_coords_z = new_coords[1];
    int new_coords_y = new_coords[2];
    int new_coords_x = new_coords[3];
    
    int cnt = 0;
    int cnt2 = 0;
    // for (int dz = -1*z_range; dz <= z_range; ++dz) {
    for (int dz = -1*z_range; dz <= z_range; ++dz) {
        int z_coord = new_coords_z + dz;
        if (z_coord < 0 || z_coord >= R1) continue;

        for (int dy = -1*y_range; dy <= y_range; ++dy) {
            int y_coord = new_coords_y + dy;
            if (y_coord < 0 || y_coord >= R2) continue;

            for (int dx = -1*x_range; dx <= x_range; ++dx) {
                int x_coord = new_coords_x + dx;
                if (x_coord < 0 || x_coord >= R3) continue;

                int index = batch_idx * R1 * R2 * R3 + \
                            z_coord * R2 * R3 + \
                            y_coord * R3 + \
                            x_coord;
                int neighbor_idx = point_indices[index];
                if (neighbor_idx < 0) continue;
                
                float x_per = xyz[neighbor_idx*3 + 0];
                float y_per = xyz[neighbor_idx*3 + 1];
                float z_per = xyz[neighbor_idx*3 + 2];

                float dist2 = (x_per - new_x) * (x_per - new_x) + (y_per - new_y) * (y_per - new_y) + (z_per - new_z) * (z_per - new_z);

                if (dist2 > radius2) continue;
                
                ++cnt2;

                if (cnt < nsample) {
                    if (cnt == 0) {
                        for (int l = 0; l < nsample; ++l) {
                            idx[l] = neighbor_idx;
                        }
                    }
                    idx[cnt] = neighbor_idx;
                    ++cnt;
                }
                // else {
                //     float rnd = curand_uniform(&state);
                //     if (rnd < (float(nsample) / cnt2)) {
                //         int insertidx = ceilf(curand_uniform(&state) * nsample) - 1;
                //         idx[insertidx] = neighbor_idx;
                //     }
                // }
            }
        }
    }
   if (cnt == 0) idx[0] = -1;
}


void voxel_query_kernel_launcher_stack(int M, int R1, int R2, int R3, int nsample,
    float radius, int z_range, int y_range, int x_range, const float *new_xyz, 
    const float *xyz, const int *new_coords, const int *point_indices, int *idx) {
    // :param new_coords: (M1 + M2 ..., 4) centers of the voxel query
    // :param point_indices: (B, Z, Y, X) 
    // output:
    //      idx: (M1 + M2, nsample)

    cudaError_t err;

    dim3 blocks(DIVUP(M, THREADS_PER_BLOCK));  // blockIdx.x(col), blockIdx.y(row)
    dim3 threads(THREADS_PER_BLOCK);

    voxel_query_kernel_stack<<<blocks, threads>>>(M, R1, R2, R3, nsample, radius, z_range, y_range, x_range, new_xyz, xyz, new_coords, point_indices, idx);
    // cudaDeviceSynchronize();  // for using printf in kernel function

    err = cudaGetLastError();
    if (cudaSuccess != err) {
        fprintf(stderr, "CUDA kernel failed : %s\n", cudaGetErrorString(err));
        exit(-1);
    }
}




__global__ void cube_query_kernel_stack(int B, int M, float radius_x, float radius_y, float radius_z, int nsample, \
    const float *new_xyz, const int *new_xyz_batch_cnt, const float *xyz, const int *xyz_batch_cnt, int *idx, float *non_padding) {
    // :param xyz: (N1 + N2 ..., 3) xyz coordinates of the features
    // :param xyz_batch_cnt: (batch_size), [N1, N2, ...]
    // :param new_xyz: (M1 + M2 ..., 3) centers of the ball query
    // :param new_xyz_batch_cnt: (batch_size), [M1, M2, ...]
    // output:
    //      idx: (M, nsample)
    //      non_padding: (M, nsample), 0 denotes padding, 1 denotes non_paddings 
    int pt_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (pt_idx >= M) return;

    int bs_idx = 0, pt_cnt = new_xyz_batch_cnt[0];
    for (int k = 1; k < B; k++){
        if (pt_idx < pt_cnt) break;
        pt_cnt += new_xyz_batch_cnt[k];
        bs_idx = k;
    }

    int xyz_batch_start_idx = 0;
    for (int k = 0; k < bs_idx; k++) xyz_batch_start_idx += xyz_batch_cnt[k];
    // for (int k = 0; k < bs_idx; k++) new_xyz_batch_start_idx += new_xyz_batch_cnt[k];

    new_xyz += pt_idx * 3;
    xyz += xyz_batch_start_idx * 3;
    idx += pt_idx * nsample;
    non_padding += pt_idx * nsample;

    // float radius2 = radius * radius;
    float new_x = new_xyz[0];
    float new_y = new_xyz[1];
    float new_z = new_xyz[2];
    int n = xyz_batch_cnt[bs_idx];

    int cnt = 0;
    for (int k = 0; k < n; ++k) {
        float x = xyz[k * 3 + 0];
        float y = xyz[k * 3 + 1];
        float z = xyz[k * 3 + 2];
        float dz = abs(new_z - z);
        if (dz < radius_z) {
            float dy = abs(new_y - y);
            if (dy < radius_y) {
                float dx = abs(new_x - x);
                if (dx < radius_x) {
                    if (cnt == 0) {
                        // 第0个的时候，把nsample个位置都填成第0个
                        // 相当于padding的是第0个元素
                        for (int l = 0; l < nsample; ++l){
                            idx[l] = k;
                        }
                    }
                    idx[cnt] = k;
                    // non_padding默认全零的，把non_padding部分置1
                    non_padding[cnt] = 1;
                    ++cnt;
                    // 多于nsample的时候，直接丢弃
                    if (cnt >= nsample) break;
                }
            }
        }
    }
    if (cnt == 0) idx[0] = -1;
}


void cube_query_kernel_launcher_stack(int B, int M, float radius_x, float radius_y, float radius_z, int nsample,
    const float *new_xyz, const int *new_xyz_batch_cnt, const float *xyz, const int *xyz_batch_cnt, int *idx, float *non_padding){
    // :param xyz: (N1 + N2 ..., 3) xyz coordinates of the features
    // :param xyz_batch_cnt: (batch_size), [N1, N2, ...]
    // :param new_xyz: (M1 + M2 ..., 3) centers of the ball query
    // :param new_xyz_batch_cnt: (batch_size), [M1, M2, ...]
    // output:
    //      idx: (M, nsample)
    //      non_padding: (M, nsample), 0 denotes padding, 1 denotes non_padding 

    cudaError_t err;

    dim3 blocks(DIVUP(M, THREADS_PER_BLOCK));  // blockIdx.x(col), blockIdx.y(row)
    dim3 threads(THREADS_PER_BLOCK);

    cube_query_kernel_stack<<<blocks, threads>>>(B, M, radius_x, radius_y, radius_z, nsample, new_xyz, new_xyz_batch_cnt, xyz, xyz_batch_cnt, idx, non_padding);
    // cudaDeviceSynchronize();  // for using printf in kernel function
    err = cudaGetLastError();
    if (cudaSuccess != err) {
        fprintf(stderr, "CUDA kernel failed : %s\n", cudaGetErrorString(err));
        exit(-1);
    }
}

