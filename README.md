**2 - CUDA Proof of Work**

The application implements a simplified blockchain miner that runs on the GPU using CUDA.
Each block contains the hash of the previous block, the Merkle root of the transactions, and a nonce found
through Proof-of-Work on the GPU, with all computations accelerated on the graphics card.

**Building the Merkle root on the GPU:**
Two CUDA kernels are used to build the Merkle tree level by level.
initial_hash_kernel: each thread computes SHA256 on one transaction and writes the hash into
the initial buffer.
combine_hashes_kernel: each thread combines pairs of hashes (duplicating the last hash if
the count is odd), concatenates the two strings, and applies SHA256 for the next level.
The final result, the Merkle root (64 hex characters + terminator), is copied back to the host.

**Nonce search (Proof of Work) on the GPU:**
A massive kernel, find_nonce_kernel, is launched, where each thread tries a different nonce.
Each thread takes the base content of the block and appends the string representation of the nonce.
It applies SHA256 and, if the resulting hash is less than or equal to the difficulty (a prefix of zeros),
it uses atomic operations (atomicMin/atomicExch) to keep track of the smallest valid nonce found.
After synchronization, the host retrieves the found nonce and reconstructs the final hash for output.

**Application flow:**
warm_up_gpu: allocates and frees a dummy buffer on the GPU to initialize the drivers.
miner.cpp reads the test file, grouping transactions into blocks of at most N transactions.
For each block: construct_merkle_root is called on the GPU and the computation time is measured,
the block content (prev_hash + merkle_root) is built on the host,
find_nonce is called on the GPU and the nonce-finding time is measured, and afterward
the output file is written with BLOCK_ID, NONCE, BLOCK_HASH, and the Merkle and Proof-of-Work times.
At the end, the cumulative total times are written.
I also added detailed comments in the code to make it easier to understand each part of the program.
