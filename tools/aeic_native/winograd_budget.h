#pragma once
#include <algorithm>
#include <cstdint>
// Pinned ncnn ARM F(2,3) allocations, including padding and thread scratch.
namespace aeic {
struct Win23Budget {
    uint64_t transformed_weights = 0, workspace = 0, border = 0;
    uint64_t inference = 0, pipeline = 0;
    bool allowed = false;
};
inline uint64_t round_up(uint64_t x, uint64_t unit) { return (x + unit - 1) / unit * unit; }
inline Win23Budget win23_arch(int ci, int co, int h, int w, int nt,
                             uint64_t l2_bytes, int physical_cpus, bool arm64) {
    Win23Budget b;
    if (ci < 1 || co < 1 || ci > 256 || co > 256 || h < 1 || w < 1 || h > 1024 || w > 1024 || nt < 1 || nt > 4) return b;
    const int unit = arm64 ? 8 : 4;
    const int l2 = int(std::min<uint64_t>(l2_bytes / 4, 1u << 28));
    int tk = std::max(unit, (std::max(0, l2 - (arm64 ? 32 : 16)) / (arm64 ? 12 : 8)) / unit * unit);
    int nk = (ci + tk - 1) / tk;
    tk = std::min(tk, int(round_up((ci + nk - 1) / nk, unit)));
    int tm = unit * std::min(nt, std::max(1,physical_cpus));
    int nm = (co + tm - 1) / tm;
    tm = std::min(tm, int(round_up((co + nm - 1) / nm, unit)));
    if (nt > 1) tm = std::min(tm, int(round_up(std::max(1,tm / nt),unit)));
    tm = std::max(unit,tm);
    const int n = int(uint64_t((h + 1) / 2) * ((w + 1) / 2));
    int ts = tk >= ci ? (l2 - tm * tk) / tk : (l2 - tm * tk) / (tm + tk);
    int tn = std::max(4, ts / 4 * 4);
    int nn = (n + tn - 1) / tn;
    tn = std::max(4,std::min(tn,int(round_up((n + nn - 1) / nn,4))));
    nk = (ci + tk - 1) / tk;
    nm = (co + tm - 1) / tm;
    nn = (n + tn - 1) / tn;
    const uint64_t batch_bytes = 16 * 4;
    b.transformed_weights = uint64_t(tk) * nk * tm * nm * batch_bytes;
    const uint64_t bt = uint64_t(tk) * tn * nk * nn * batch_bytes;
    const int b_threads = nt > 1 && nk * nn < nt ? 1 : nt;
    const uint64_t b_scratch = uint64_t(tn) * tk * batch_bytes * b_threads;
    const uint64_t top_scratch = uint64_t(tn) * tm * batch_bytes * nt;
    b.workspace = bt + std::max(b_scratch,top_scratch);
    b.border = uint64_t(ci) * (h + 2) * (w + 2) * 4;
    b.inference = b.transformed_weights + b.workspace + b.border;
    const uint64_t original_weights = uint64_t(ci) * co * 9 * 4;
    const uint64_t kernel_scratch = uint64_t(tk) * tm * batch_bytes * nt;
    b.pipeline = original_weights + b.transformed_weights + kernel_scratch + uint64_t(co) * 4;
    b.allowed = b.transformed_weights <= (8u << 20) && b.inference <= (32u << 20) && b.pipeline <= (16u << 20);
    return b;
}
inline Win23Budget win23_budget(int ci,int co,int h,int w,int nt,uint64_t l2,int cpus) {
    // Both supported ARM ABIs use bounded transforms; use the larger allocation bound.
    auto a = win23_arch(ci,co,h,w,nt,l2,cpus,false);
    auto b = win23_arch(ci,co,h,w,nt,l2,cpus,true);
    Win23Budget result;
    result.transformed_weights = std::max(a.transformed_weights,b.transformed_weights);
    result.workspace = std::max(a.workspace,b.workspace);
    result.border = std::max(a.border,b.border);
    result.inference = std::max(a.inference,b.inference);
    result.pipeline = std::max(a.pipeline,b.pipeline);
    result.allowed = a.allowed && b.allowed;
    return result;
}
}
