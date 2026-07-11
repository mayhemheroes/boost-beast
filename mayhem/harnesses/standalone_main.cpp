//
// standalone_main.cpp — a tiny run-once driver for the Boost.Beast libFuzzer harnesses.
//
// The beast fuzz harnesses (libs/beast/test/fuzz/*.cpp) expose the libFuzzer entry point
// LLVMFuzzerTestOneInput(data, size). When we link a harness against libFuzzer
// ($LIB_FUZZING_ENGINE) we get the fuzzing binary; when we link it against THIS file
// instead we get a `-standalone` reproducer that reads each path on argv, feeds the bytes
// to the harness once, and exits. No libFuzzer runtime, so it can replay a single crashing
// input under a debugger / ASan. This file is additive (lives only in mayhem/).
//
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

int main(int argc, char** argv)
{
    for (int i = 1; i < argc; ++i) {
        FILE* f = fopen(argv[i], "rb");
        if (!f) { perror(argv[i]); return 1; }
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        std::vector<uint8_t> buf(n > 0 ? static_cast<size_t>(n) : 0);
        if (n > 0 && fread(buf.data(), 1, static_cast<size_t>(n), f) != static_cast<size_t>(n)) {
            fclose(f);
            return 1;
        }
        fclose(f);
        LLVMFuzzerTestOneInput(buf.data(), buf.size());
    }
    return 0;
}
