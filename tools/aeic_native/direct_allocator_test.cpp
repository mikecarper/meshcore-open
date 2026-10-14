#include "direct_allocator.h"
#include "net.h"
#include <cstdio>

int main() {
    ncnn::Mat output;
    {
        ncnn::Net net;
        net.opt.num_threads = 1;
        net.opt.use_packing_layout = false;
        net.opt.use_local_pool_allocator = false;
        net.opt.blob_allocator = aeic::direct_allocator();
        net.opt.workspace_allocator = aeic::direct_allocator();
        const char* graph = "7767517\n2 2\nInput input 0 1 in0\nInterp resize 1 1 in0 out0 0=1 1=2.0 2=2.0\n";
        if (net.load_param_mem(graph)) return 1;
        ncnn::Mat input(2, 2, 2);
        for (int c = 0; c < 2; ++c) {
            float* values = input.channel(c);
            for (int p = 0; p < 4; ++p) values[p] = float(c * 4 + p);
        }
        auto extractor = net.create_extractor();
        if (extractor.input("in0", input) || extractor.extract("out0", output)) return 2;
        if (!output.refcount || output.allocator != aeic::direct_allocator()) return 3;
    }
    if (output.dims != 3 || output.c != 2 || output.h != 4 || output.w != 4) return 4;
    for (int c = 0; c < 2; ++c) {
        const float* values = output.channel(c);
        for (int h = 0; h < 4; ++h) for (int w = 0; w < 4; ++w)
            if (values[h * 4 + w] != float(c * 4 + (h / 2) * 2 + w / 2)) return 5;
    }
    output.release();
    std::puts("PASS: direct output retains owned allocation after Net destruction without local pool clone");
    return 0;
}
