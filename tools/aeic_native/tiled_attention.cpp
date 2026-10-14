#include "tiled_attention.h"

#include "layer.h"
#include "layer_type.h"
#include "modelbin.h"
#include "net.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace aeic {
namespace {

ncnn::Option scalar_options(const ncnn::Option& input) {
    ncnn::Option opt = input;
    opt.use_packing_layout = false;
    opt.use_fp16_packed = false;
    opt.use_fp16_storage = false;
    opt.use_fp16_arithmetic = false;
    opt.use_bf16_packed = false;
    opt.use_bf16_storage = false;
    return opt;
}

class TiledAttention : public ncnn::Layer {
public:
    TiledAttention() {
        one_blob_only = true;
        support_inplace = false;
        support_packing = false;
    }

    ~TiledAttention() override { destroy_pipeline(ncnn::Option()); }

    int load_param(const ncnn::ParamDict& pd) override {
        embed_ = pd.get(0, 0);
        heads_ = pd.get(1, 1);
        weight_size_ = pd.get(2, 0);
        kdim_ = pd.get(3, embed_);
        vdim_ = pd.get(4, embed_);
        tile_rows_ = pd.get(20, 128);
        if (embed_ <= 0 || embed_ > 1280 || heads_ <= 0 || embed_ % heads_ ||
            weight_size_ <= 0 || weight_size_ % embed_ ||
            tile_rows_ < 1 || tile_rows_ > 512 ||
            pd.get(5, 0) || pd.get(7, 0) || pd.get(18, 0)) return -1;
        qdim_ = weight_size_ / embed_;
        if (qdim_ <= 0 || qdim_ > 1280 || qdim_ != kdim_ || qdim_ != vdim_) return -1;
        scale_ = pd.get(6, 1.f / std::sqrt(float(embed_ / heads_)));
        return std::isfinite(scale_) && scale_ > 0 ? 0 : -1;
    }

    int load_model(const ncnn::ModelBin& mb) override {
        // Exact MultiHeadAttention load_model order. Half disk weights are
        // expanded by ModelBin to FP32; entropy-model precision is untouched.
        qw_ = mb.load(weight_size_, 0); qb_ = mb.load(embed_, 1);
        kw_ = mb.load(embed_ * kdim_, 0); kb_ = mb.load(embed_, 1);
        vw_ = mb.load(embed_ * vdim_, 0); vb_ = mb.load(embed_, 1);
        ow_ = mb.load(embed_ * qdim_, 0); ob_ = mb.load(qdim_, 1);
        return qw_.empty() || qb_.empty() || kw_.empty() || kb_.empty() ||
               vw_.empty() || vb_.empty() || ow_.empty() || ob_.empty() ? -100 : 0;
    }

    int create_pipeline(const ncnn::Option& original) override {
        const ncnn::Option opt = scalar_options(original);
        int ret = projection(q_, qw_, qb_, qdim_, embed_, false, true, scale_, opt);
        if (!ret) ret = projection(k_, kw_, kb_, kdim_, embed_, false, true, 1.f, opt);
        if (!ret) ret = projection(v_, vw_, vb_, vdim_, embed_, false, true, 1.f, opt);
        if (!ret) ret = projection(o_, ow_, ob_, embed_, qdim_, true, false, 1.f, opt);
        ncnn::Option one_thread = opt; one_thread.num_threads = 1;
        if (!ret) ret = dynamic_gemm(scores_, true, false, false, one_thread);
        if (!ret) ret = dynamic_gemm(values_, false, true, true, one_thread);
        if (!ret) {
            softmax_ = ncnn::create_layer_cpu(ncnn::LayerType::Softmax);
            if (!softmax_) ret = -100;
            else {
                ncnn::ParamDict pd; pd.set(0, 1); pd.set(1, 1);
                ret = softmax_->load_param(pd);
                if (!ret) ret = softmax_->create_pipeline(opt);
            }
        }
        if (ret) destroy_pipeline(opt);
        return ret;
    }

    int destroy_pipeline(const ncnn::Option& opt) override {
        ncnn::Layer** layers[] = {&q_, &k_, &v_, &o_, &scores_, &values_, &softmax_};
        for (ncnn::Layer** ptr : layers) {
            if (*ptr) { (*ptr)->destroy_pipeline(opt); delete *ptr; *ptr = nullptr; }
        }
        return 0;
    }

    int forward(const ncnn::Mat& input, ncnn::Mat& output,
                const ncnn::Option& original) const override {
        if (input.dims != 2 || input.w != qdim_ || input.h <= 0 || input.h > 5184 ||
            input.elempack != 1 || input.elembits() != 32) return -1;
        const ncnn::Option opt = scalar_options(original);
        const int tokens = input.h, per_head = embed_ / heads_;
        ncnn::Mat q, k, v;
        int ret = q_->forward(input, q, opt);
        if (!ret) ret = k_->forward(input, k, opt);
        if (!ret) ret = v_->forward(input, v, opt);
        if (ret) return ret;
        if (q.w != tokens || k.w != tokens || v.w != tokens ||
            q.h != embed_ || k.h != embed_ || v.h != embed_) return -1;
        ncnn::Mat context(tokens, embed_, 4u, opt.blob_allocator);
        if (context.empty()) return -100;
        // Softmax still sees every key for each query. Splitting queries and
        // heads only changes scheduling; it does not approximate attention.
        // Parallel heads have disjoint output rows. Each head keeps only one
        // query tile, so live scores are at most threads * tile_rows * tokens.
        std::vector<int> errors(heads_, 0);
        #pragma omp parallel for num_threads(opt.num_threads)
        for (int head = 0; head < heads_; ++head) {
            errors[head] = head_forward(head, tokens, per_head, q, k, v, context, opt);
        }
        for (int error : errors) if (error) return error;
        q.release(); k.release(); v.release();
        return o_->forward(context, output, opt);
    }

private:
    int head_forward(int head, int tokens, int per_head, const ncnn::Mat& q,
                     const ncnn::Mat& k, const ncnn::Mat& v, ncnn::Mat& context,
                     const ncnn::Option& opt) const {
        ncnn::Option one_thread = opt; one_thread.num_threads = 1;
        const ncnn::Mat kh = k.row_range(head * per_head, per_head);
        const ncnn::Mat vh = v.row_range(head * per_head, per_head);
        for (int start = 0; start < tokens; start += tile_rows_) {
            const int rows = std::min(tile_rows_, tokens - start);
            ncnn::Mat qt(rows, per_head, 4u, opt.workspace_allocator);
            if (qt.empty()) return -100;
            for (int feature = 0; feature < per_head; ++feature) {
                std::memcpy(qt.row(feature), q.row(head * per_head + feature) + start,
                            size_t(rows) * sizeof(float));
            }
            std::vector<ncnn::Mat> inputs(2), results(1);
            inputs[0] = qt; inputs[1] = kh;
            int ret = scores_->forward(inputs, results, one_thread);
            if (ret) return ret;
            ncnn::Mat score = results[0];
            if (score.w != tokens || score.h != rows) return -1;
            ret = softmax_->forward_inplace(score, one_thread);
            if (ret) return ret;
            inputs[0] = score; inputs[1] = vh; results[0] = ncnn::Mat();
            ret = values_->forward(inputs, results, one_thread);
            if (ret) return ret;
            const ncnn::Mat& tile = results[0];
            if (tile.w != rows || tile.h != per_head) return -1;
            for (int feature = 0; feature < per_head; ++feature) {
                std::memcpy(context.row(head * per_head + feature) + start,
                            tile.row(feature), size_t(rows) * sizeof(float));
            }
        }
        return 0;
    }

    static int projection(ncnn::Layer*& layer, const ncnn::Mat& weight,
                          const ncnn::Mat& bias, int in, int out,
                          bool trans_a, bool trans_output, float alpha,
                          const ncnn::Option& opt) {
        layer = ncnn::create_layer_cpu(ncnn::LayerType::Gemm);
        if (!layer) return -100;
        ncnn::ParamDict pd;
        pd.set(0, alpha); pd.set(2, int(trans_a)); pd.set(3, 1);
        pd.set(4, 0); pd.set(5, 1); pd.set(6, 1);
        pd.set(7, 0); pd.set(8, out); pd.set(9, in); pd.set(10, 4);
        pd.set(11, 0); pd.set(12, 1); pd.set(13, 1); pd.set(14, int(trans_output));
        int ret = layer->load_param(pd);
        ncnn::Mat weights[2] = {weight, bias};
        if (!ret) ret = layer->load_model(ncnn::ModelBinFromMatArray(weights));
        if (!ret) ret = layer->create_pipeline(opt);
        return ret;
    }

    static int dynamic_gemm(ncnn::Layer*& layer, bool trans_a, bool trans_b,
                            bool trans_output, const ncnn::Option& opt) {
        layer = ncnn::create_layer_cpu(ncnn::LayerType::Gemm);
        if (!layer) return -100;
        ncnn::ParamDict pd;
        pd.set(2, int(trans_a)); pd.set(3, int(trans_b));
        pd.set(4, 0); pd.set(5, 0); pd.set(6, 1); pd.set(10, -1);
        pd.set(11, 0); pd.set(12, 1); pd.set(13, 1); pd.set(14, int(trans_output));
        int ret = layer->load_param(pd);
        if (!ret) ret = layer->load_model(ncnn::ModelBinFromMatArray(nullptr));
        if (!ret) ret = layer->create_pipeline(opt);
        return ret;
    }

    int embed_ = 0, heads_ = 1, weight_size_ = 0, qdim_ = 0, kdim_ = 0, vdim_ = 0;
    int tile_rows_ = 128;
    float scale_ = 1.f;
    ncnn::Mat qw_, qb_, kw_, kb_, vw_, vb_, ow_, ob_;
    ncnn::Layer *q_ = nullptr, *k_ = nullptr, *v_ = nullptr, *o_ = nullptr;
    ncnn::Layer *scores_ = nullptr, *values_ = nullptr, *softmax_ = nullptr;
};

ncnn::Layer* create_tiled_attention(void*) { return new TiledAttention(); }

} // namespace

int register_tiled_attention(ncnn::Net& net) {
    return net.register_custom_layer("AEICTiledAttention", create_tiled_attention);
}
} // namespace aeic
