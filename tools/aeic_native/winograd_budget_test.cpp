#undef NDEBUG
#include "winograd_budget.h"
#include <cassert>
#include <cstdio>
int main() {
    using namespace aeic;
    auto known=win23_arch(128,3,16,16,4,262144,4,false);
    assert(known.workspace==1048576); // BT plus B_tile, excludes model and bordered input.
    assert(known.inference>known.workspace && known.allowed);
    for (auto cache : {65536u,262144u,524288u,1048576u,2097152u})
        for (auto threads : {1,2,4}) {
            auto small=win23_budget(128,128,32,32,threads,cache,4);
            assert(small.allowed && small.transformed_weights<=8388608 && small.inference<=33554432);
            auto oversized=win23_budget(256,256,576,576,threads,cache,4);
            assert(!oversized.allowed && oversized.inference>33554432);
            assert(!win23_budget(1280,1280,32,32,threads,cache,4).allowed);
            auto tile=win23_budget(256,256,20,128,threads,cache,4);
            assert(tile.allowed && tile.inference<=33554432);
        }
    assert(!win23_budget(128,128,1025,16,4,262144,4).allowed);
    assert(!win23_budget(128,128,16,1025,4,262144,4).allowed);
    std::puts("WIN23_BUDGET_TEST_PASS exact_scratch=true invalid_large_channels_rejected=true");
}
