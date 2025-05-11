tema 2 - Cuda Proof Of Work

Aplicatia implementeaza un miner simplificat de blockchain care ruleaza pe GPU folosind CUDA.
Fiecare bloc contine hash-ul blocului anterior, Merkle root-ul tranzactiilor si un nonce gasit
prin Proof-of-Work pe GPU, toate calculele fiind accelerate pe placa grafica.

Constructia Merkle root pe GPU:
Se folosesc doua kernel-uri CUDA pentru a ridica arborele Merkle nivel cu nivel.
initial_hash_kernel: fiecare thread calculeaza SHA256 pe o tranzactie si scrie hash-ul in
bufferul initial.
combine_hashes_kernel: fiecare thread combina perechi de hash-uri (duplicand ultimul hash daca
numarul e impar), concateneaza cele doua string-uri si aplica SHA256 pentru nivelul urmator.
Rezultatul final, Merkle root-ul (64 caractere hex + terminator), este copiat inapoi pe host.

Cautarea nonce-ului (Proof of Work) pe GPU:
Se lanseaza un kernel masiv, find_nonce_kernel, unde fiecare thread incearca un nonce diferit.
Fiecare thread preia continutul de baza al blocului si ataseaza reprezentarea string a nonce-ului.
Aplica SHA256 si, daca hash-ul rezultat e mai mic sau egal decat dificultatea (prefix de zerouri),
foloseste operatii atomice (atomicMin/atomicExch) pentru a retine cel mai mic nonce valid gasit.
Dupa sincronizare, host-ul recupereaza nonce-ul gasit si recompune hash-ul final pentru iesire.

Flow-ul aplicatiei:
warm_up_gpu: aloca si elibereaza un buffer dummy pe GPU pentru a initializa driverele.
miner.cpp citeste fisierul de test, grupand tranzactiile in blocuri de maxim N tranzactii.
Pentru fiecare bloc: se apeleaza construct_merkle_root pe GPU si se masoara timpul de calcul,
se construieste continutul blocului (prev_hash + merkle_root) pe host,
se apeleaza find_nonce pe GPU si se masoara timpul de gasire nonce si dupa
se scrie in fisierul de iesire BLOCK_ID, NONCE, BLOCK_HASH, timpii pentru Merkle si Proof-of-Work.
La final se scriu timpii totali cumulati.
Am adaugat si comentarii detaliate in cod pentru a usura intelegerea fiecarei parti a programului.
