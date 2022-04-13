#include <stdio.h>

#define CACHE_SIZE 128
// Analysis kernels

__device__ int row_idx = 0;

extern "C" __global__ void analysis_lower(uint n_rows, uint *max_lvl, volatile bool *analyzed_rows, volatile uint *row_levels, uint *rows, uint *cols) {
    int row = atomicAdd(&row_idx, 1);
    if (row >= n_rows)
        return;

    uint row_start = rows[row];
    uint row_end = rows[row + 1] - 1;

    uint col;
    uint row_lvl = 0; // We determine to which level this row is going to be added
    for (uint i=row_start; i<row_end; i++) {
        col = cols[i];
        while (!analyzed_rows[col])
            continue;
        uint col_lvl = row_levels[col];
        if (row_lvl <= col_lvl)
            row_lvl = col_lvl + 1;
    }

    atomicMax(max_lvl, row_lvl);
    row_levels[row] = row_lvl;
    analyzed_rows[row] = true;
    // Wrap up
    if (row == n_rows - 1)
        row_idx = 0;
}

extern "C" __global__ void analysis_upper(uint n_rows, uint *max_lvl, volatile bool *analyzed_rows, volatile uint *row_levels, uint *rows, uint *cols) {
    int row = n_rows - 1 - atomicAdd(&row_idx, 1);
    if (row < 0)
        return;

    uint row_start = rows[row];
    uint row_end = rows[row + 1] - 1;

    uint col;
    uint row_lvl = 0;
    for (uint i=row_end; i>row_start; i--) {
        col = cols[i];
        while (!analyzed_rows[col])
            continue;
        uint col_lvl = row_levels[col];
        if (row_lvl <= col_lvl)
            row_lvl = col_lvl + 1;
    }

    atomicMax(max_lvl, row_lvl);
    row_levels[row] = row_lvl;
    analyzed_rows[row] = true;
    // Wrap up
    if (row == 0)
        row_idx = 0;
}

// Solve kernels


template<typename Float>
__device__ void solve_lower(uint nrhs, uint nrows, uint *stack_id, uint *levels, volatile bool *solved_rows, uint* rows, uint* columns, Float* values, volatile Float* x) {

    __shared__ uint lvl_idx;
    __shared__ uint cols_cache[CACHE_SIZE];
    __shared__ Float vals_cache[CACHE_SIZE];

    int thread_idx = threadIdx.x;
    // The current block solves the row at index *stack_id in levels
    if (thread_idx == 0) {
        lvl_idx = atomicAdd(stack_id, 1);
    }
    __syncthreads();

    if (lvl_idx >= nrows)
        return;

    uint row = levels[lvl_idx];
    uint row_start = rows[row];
    uint row_end = rows[row + 1] - 1;
    Float diag_entry = values[row_end];
    Float r;
    if (thread_idx < nrhs)
        r = x[thread_idx * nrows + row];
    uint col;
    Float val;
    for (int i=row_start; i<row_end; ++i) {
        uint cache_idx = (i-row_start) % CACHE_SIZE;
        if (cache_idx == 0) {
            // Update the cache
            if (i + thread_idx < (int)row_end) {
                cols_cache[thread_idx] = columns[i + thread_idx];
                vals_cache[thread_idx] = values[i + thread_idx];
            }
            __syncthreads();
        }

        if (thread_idx < nrhs) {
            // Read current column and corresponding entry in the cache
            col = cols_cache[cache_idx];
            val = vals_cache[cache_idx];
        }
        // Busy wait for the corresponding entry in x to be solved
        if (thread_idx == 0) {
            while (!solved_rows[col])
                continue;
        }
        __syncthreads();

        if (thread_idx < nrhs)
            r -= val * x[thread_idx * nrows + col];

    }

    // Write the final value
    if (thread_idx < nrhs)
        x[thread_idx * nrows + row] = r / diag_entry;

    // Make sure we write all entries before signaling other blocks
    __threadfence();
    __syncthreads();

    if (thread_idx != 0)
        return;

    // Signal other blocks that this entry is available
    solved_rows[row] = true;
}

template<typename Float>
__device__ void solve_upper(uint nrhs, uint nrows, uint *stack_id, uint *levels, volatile bool *solved_rows, uint* rows, uint* columns, Float* values, volatile Float* x) {

    __shared__ uint lvl_idx;
    __shared__ uint cols_cache[CACHE_SIZE];
    __shared__ Float vals_cache[CACHE_SIZE];

    int thread_idx = threadIdx.x;
    // The current block solves the row at index *stack_id in levels
    if (thread_idx == 0)
        lvl_idx = atomicAdd(stack_id, 1);
    __syncthreads();

    if (lvl_idx >= nrows)
        return;

    uint row = levels[lvl_idx];
    uint row_start = rows[row];
    uint row_end = rows[row + 1] - 1;
    Float diag_entry = values[row_start];
    Float r;
    if (thread_idx < nrhs)
        r = x[thread_idx * nrows + row];
    uint col;
    Float val;
    for (int i=row_end; i>row_start; --i) {
        int cache_idx = (row_end - i) % CACHE_SIZE;
        if (cache_idx == 0) {
            // Update the cache
            if (i - thread_idx > (int)row_start) {
                vals_cache[thread_idx] = values[i - thread_idx];
                cols_cache[thread_idx] = columns[i - thread_idx];
            }
            __syncthreads();
        }

        if (thread_idx < nrhs) {
            // Read current column and corresponding entry in the cache
            col = cols_cache[cache_idx];
            val = vals_cache[cache_idx];
        }
        // Busy wait for the corresponding entry in x to be solved
        if (thread_idx == 0) {
            while (!solved_rows[col])
                continue;
        }
        __syncthreads();

        if (thread_idx < nrhs)
            r -= val * x[thread_idx * nrows + col];

    }

    // Write the final value
    if (thread_idx < nrhs)
        x[thread_idx * nrows + row] = r / diag_entry;


    // Make sure we write all entries before signaling other blocks
    __threadfence();
    __syncthreads();

    if (thread_idx != 0)
        return;

    // Signal other blocks that this entry is available
    solved_rows[row] = true;
}

extern "C" __global__ void solve_lower_float(uint nrhs, uint nrows, uint *stack_id,  uint *levels, bool *solved_rows, uint *rows, uint *columns, float *values, float*x) {
    solve_lower<float>(nrhs, nrows, stack_id, levels, solved_rows, rows, columns, values, x);
}

extern "C" __global__ void solve_lower_double(uint nrhs, uint nrows, uint *stack_id, uint *levels, bool *solved_rows, uint *rows, uint *columns, double *values, double*x) {
    solve_lower<double>(nrhs, nrows, stack_id, levels, solved_rows, rows, columns, values, x);
}

extern "C" __global__ void solve_upper_float(uint nrhs, uint nrows, uint *stack_id, uint *levels, bool *solved_rows, uint *rows, uint *columns, float *values, float*x) {
    solve_upper<float>(nrhs, nrows, stack_id, levels, solved_rows, rows, columns, values, x);
}

extern "C" __global__ void solve_upper_double(uint nrhs, uint nrows, uint *stack_id, uint *levels, bool *solved_rows, uint *rows, uint *columns, double *values, double*x) {
    solve_upper<double>(nrhs, nrows, stack_id, levels, solved_rows, rows, columns, values, x);
}
