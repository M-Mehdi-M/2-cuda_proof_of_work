#include <stdio.h>
#include <stdint.h>
#include "utils.h"
#include <string.h>
#include <stdlib.h>
#include <cuda_runtime.h>

// CUDA sprintf alternative for nonce finding. Converts integer to its string representation. Returns string's length.
__device__ int intToString(uint64_t num, char* out) {
    if (num == 0) {
        out[0] = '0';
        out[1] = '\0';
        return 2;
    }

    int i = 0;
    while (num != 0) {
        int digit = num % 10;
        num /= 10;
        out[i++] = '0' + digit;
    }

    // Reverse the string
    for (int j = 0; j < i / 2; j++) {
        char temp = out[j];
        out[j] = out[i - j - 1];
        out[i - j - 1] = temp;
    }
    out[i] = '\0';
    return i;
}

// CUDA strlen implementation.
__host__ __device__ size_t d_strlen(const char *str) {
    size_t len = 0;
    while (str[len] != '\0') {
        len++;
    }
    return len;
}

// CUDA strcpy implementation.
__device__ void d_strcpy(char *dest, const char *src){
    int i = 0;
    while ((dest[i] = src[i]) != '\0') {
        i++;
    }
}

// CUDA strcat implementation.
__device__ void d_strcat(char *dest, const char *src){
    while (*dest != '\0') {
        dest++;
    }
    while (*src != '\0') {
        *dest = *src;
        dest++;
        src++;
    }
    *dest = '\0';
}

// Compute SHA256 and convert to hex
__host__ __device__ void apply_sha256(const BYTE *input, BYTE *output) {
    size_t input_length = d_strlen((const char *)input);
    SHA256_CTX ctx;
    BYTE buf[SHA256_BLOCK_SIZE];
    const char hex_chars[] = "0123456789abcdef";

    sha256_init(&ctx);
    sha256_update(&ctx, input, input_length);
    sha256_final(&ctx, buf);

    for (size_t i = 0; i < SHA256_BLOCK_SIZE; i++) {
        output[i * 2]     = hex_chars[(buf[i] >> 4) & 0x0F];  // High nibble
        output[i * 2 + 1] = hex_chars[buf[i] & 0x0F];         // Low nibble
    }
    output[SHA256_BLOCK_SIZE * 2] = '\0'; // Null-terminate
}

// Compare two hashes
__host__ __device__ int compare_hashes(BYTE* hash1, BYTE* hash2) {
    for (int i = 0; i < SHA256_HASH_SIZE; i++) {
        if (hash1[i] < hash2[i]) {
            return -1; // hash1 is lower
        } else if (hash1[i] > hash2[i]) {
            return 1; // hash2 is lower
        }
    }
    return 0; // hashes are equal
}

// Kernel to compute SHA256 hash for each initial transaction
__global__ void initial_hash_kernel(const BYTE *d_transactions, int transaction_size, BYTE *d_output_hashes, int num_transactions) {
    // calculate unique thread id across all blocks
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < num_transactions) {
        // each thread hashes one transaction independently
        apply_sha256(d_transactions + idx * transaction_size, d_output_hashes + idx * SHA256_HASH_SIZE);
    }
}

// Kernel to combine pairs of hashes to form the next level of the Merkle tree
__global__ void combine_hashes_kernel(const BYTE *d_input_hashes, BYTE *d_output_hashes, int num_input_hashes) {
    // calculate unique thread id across all blocks
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    // calculate how many output hashes we'll produce at this level
    int num_output_hashes = (num_input_hashes + 1) / 2;

    if (idx < num_output_hashes) {
        // temporary buffer to store combined hash pairs
        BYTE combined_input[SHA256_HASH_SIZE * 2];

        // copy first hash of the pair
        d_strcpy((char *)combined_input, (const char *)(d_input_hashes + (2 * idx) * SHA256_HASH_SIZE));

        if ((2 * idx + 1) < num_input_hashes) {
            // if second hash exists, append it
            d_strcat((char *)combined_input, (const char *)(d_input_hashes + (2 * idx + 1) * SHA256_HASH_SIZE));
        } else {
            // if odd number of hashes, duplicate the last one
            d_strcat((char *)combined_input, (const char *)(d_input_hashes + (2 * idx) * SHA256_HASH_SIZE));
        }

        // hash the combined pair to create parent node
        apply_sha256(combined_input, d_output_hashes + idx * SHA256_HASH_SIZE);
    }
}

// TODO 1: Implement this function in CUDA
void construct_merkle_root(int transaction_size, BYTE *transactions, int max_transactions_in_a_block, int n, BYTE merkle_root[SHA256_HASH_SIZE]) {
    // handle special cases first
    if (n == 0) {
        // no transactions, return all zeros
        memset(merkle_root, '0', SHA256_HASH_SIZE -1);
        merkle_root[SHA256_HASH_SIZE-1] = '\0';
        return;
    }
    if (n == 1) {
        // only one transaction, its hash is the merkle root
        apply_sha256(transactions, merkle_root);
        return;
    }

    // allocate gpu memory
    BYTE *d_transactions;
    BYTE *d_hashes_buffer_A;
    BYTE *d_hashes_buffer_B;

    cudaMalloc(&d_transactions, n * transaction_size);
    cudaMalloc(&d_hashes_buffer_A, n * SHA256_HASH_SIZE);
    cudaMalloc(&d_hashes_buffer_B, ((n + 1) / 2) * SHA256_HASH_SIZE);

    // copy transactions to gpu
    cudaMemcpy(d_transactions, transactions, n * transaction_size, cudaMemcpyHostToDevice);

    // setup thread configuration
    int threads_per_block = 256;
    int num_blocks_initial_hash = (n + threads_per_block - 1) / threads_per_block;

    // hash all transactions in parallel
    initial_hash_kernel<<<num_blocks_initial_hash, threads_per_block>>>(d_transactions, transaction_size, d_hashes_buffer_A, n);
    cudaDeviceSynchronize();

    // prepare for merkle tree construction
    int current_num_hashes = n;
    // use double-buffering technique with pointers
    BYTE *d_current_level_ptr = d_hashes_buffer_A;
    BYTE *d_next_level_ptr = d_hashes_buffer_B;

    // build merkle tree level by level until we reach root
    while (current_num_hashes > 1) {
        int num_output_hashes = (current_num_hashes + 1) / 2;
        int num_blocks_combine = (num_output_hashes + threads_per_block - 1) / threads_per_block;

        // combine pairs of hashes to form next level
        combine_hashes_kernel<<<num_blocks_combine, threads_per_block>>>(d_current_level_ptr, d_next_level_ptr, current_num_hashes);
        cudaDeviceSynchronize();

        // swap buffers for next iteration
        BYTE *temp_ptr = d_current_level_ptr;
        d_current_level_ptr = d_next_level_ptr;
        d_next_level_ptr = temp_ptr;

        current_num_hashes = num_output_hashes;
    }

    // copy final merkle root back to host
    cudaMemcpy(merkle_root, d_current_level_ptr, SHA256_HASH_SIZE, cudaMemcpyDeviceToHost);

    // free gpu memory
    cudaFree(d_transactions);
    cudaFree(d_hashes_buffer_A);
    cudaFree(d_hashes_buffer_B);
}

// kernel to find valid nonce in parallel
__global__ void find_nonce_kernel(const BYTE *d_difficulty, uint32_t max_nonce, const BYTE *d_block_content_base, size_t base_length, uint32_t *d_min_valid_nonce, int *d_any_nonce_found_flag) {
    // each thread tries a different nonce
    uint32_t nonce = blockIdx.x * blockDim.x + threadIdx.x;

    // skip if nonce exceeds maximum
    if (nonce > max_nonce) {
        return;
    }
    // early exit if we already found a better nonce
    if (*d_any_nonce_found_flag == 1 && nonce >= *d_min_valid_nonce) {
         return;
    }

    // local buffers for this thread
    BYTE local_block_content[BLOCK_SIZE];
    BYTE local_block_hash[SHA256_HASH_SIZE];
    char nonce_str[NONCE_SIZE];

    // copy block content base to local memory
    for(size_t i=0; i < base_length; ++i) {
        local_block_content[i] = d_block_content_base[i];
    }

    // convert nonce to string
    int nonce_str_len = intToString(nonce, nonce_str);

    // append nonce string to block content
    for(int k=0; k < nonce_str_len; ++k) {
        local_block_content[base_length + k] = nonce_str[k];
    }
    local_block_content[base_length + nonce_str_len] = '\0';

    // calculate hash of block with this nonce
    apply_sha256(local_block_content, local_block_hash);

    // check if hash meets difficulty requirement
    if (compare_hashes(local_block_hash, (BYTE*)d_difficulty) <= 0) {
        // found valid nonce, update minimum atomically
        atomicMin(d_min_valid_nonce, nonce);
        atomicExch(d_any_nonce_found_flag, 1);
    }
}

// TODO 2: Implement this function in CUDA
int find_nonce(BYTE *difficulty, uint32_t max_nonce, BYTE *block_content, size_t current_length, BYTE *block_hash, uint32_t *valid_nonce) {
    // allocate gpu memory
    BYTE *d_difficulty;
    BYTE *d_block_content_base_device;
    uint32_t *d_min_valid_nonce_device;
    int *d_any_nonce_found_flag_device;

    cudaMalloc(&d_difficulty, SHA256_HASH_SIZE);
    cudaMalloc(&d_block_content_base_device, current_length);
    cudaMalloc(&d_min_valid_nonce_device, sizeof(uint32_t));
    cudaMalloc(&d_any_nonce_found_flag_device, sizeof(int));

    // copy data to gpu
    cudaMemcpy(d_difficulty, difficulty, SHA256_HASH_SIZE, cudaMemcpyHostToDevice);
    cudaMemcpy(d_block_content_base_device, block_content, current_length, cudaMemcpyHostToDevice);

    // initialize search variables
    uint32_t h_initial_min_nonce = UINT32_MAX;
    int h_initial_found_flag = 0;
    cudaMemcpy(d_min_valid_nonce_device, &h_initial_min_nonce, sizeof(uint32_t), cudaMemcpyHostToDevice);
    cudaMemcpy(d_any_nonce_found_flag_device, &h_initial_found_flag, sizeof(int), cudaMemcpyHostToDevice);

    // setup thread configuration
    int threads_per_block = 256;
    unsigned long long num_nonces_to_check = (unsigned long long)max_nonce + 1;
    // calculate number of blocks needed
    int num_blocks = (num_nonces_to_check + threads_per_block - 1) / threads_per_block;
    if (num_blocks == 0 && num_nonces_to_check > 0) num_blocks = 1;

    // launch kernel to search for nonce
    if (num_nonces_to_check > 0) {
         find_nonce_kernel<<<num_blocks, threads_per_block>>>(
            d_difficulty,
            max_nonce,
            d_block_content_base_device,
            current_length,
            d_min_valid_nonce_device,
            d_any_nonce_found_flag_device
        );
        cudaDeviceSynchronize();
    }

    // copy results back to host
    uint32_t h_min_nonce_found;
    int h_any_nonce_is_valid_flag;
    cudaMemcpy(&h_min_nonce_found, d_min_valid_nonce_device, sizeof(uint32_t), cudaMemcpyDeviceToHost);
    cudaMemcpy(&h_any_nonce_is_valid_flag, d_any_nonce_found_flag_device, sizeof(int), cudaMemcpyDeviceToHost);

    int result_status = 1;

    // if valid nonce found, compute final hash
    if (h_any_nonce_is_valid_flag == 1 && h_min_nonce_found != UINT32_MAX) {
        *valid_nonce = h_min_nonce_found;

        // recompute block hash on cpu for final result
        char nonce_string_host[NONCE_SIZE];
        sprintf(nonce_string_host, "%u", *valid_nonce);

        BYTE temp_full_block_content_host[BLOCK_SIZE];
        memcpy(temp_full_block_content_host, block_content, current_length);
        strcpy((char *)temp_full_block_content_host + current_length, nonce_string_host);

        apply_sha256(temp_full_block_content_host, block_hash);

        result_status = 0;
    }

    // free gpu memory
    cudaFree(d_difficulty);
    cudaFree(d_block_content_base_device);
    cudaFree(d_min_valid_nonce_device);
    cudaFree(d_any_nonce_found_flag_device);

    return result_status;
}

__global__ void dummy_kernel() {}

// Warm-up function
void warm_up_gpu() {
    BYTE *dummy_data;
    cudaMalloc((void **)&dummy_data, 256);
    dummy_kernel<<<1, 1>>>();
    cudaDeviceSynchronize();
    cudaFree(dummy_data);
}
