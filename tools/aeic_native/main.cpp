#include "entropy.h"
#include "png_writer.h"
#include "mat_diagnostics.h"
#include "recovery.h"
#include "tiled_attention.h"
#include "direct_allocator.h"
#include "file_hash.h"
#include "net.h"
#include <algorithm>
#include <chrono>
#include <cfenv>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <limits>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#if defined(__linux__)
#include <sys/resource.h>
#endif

namespace {
using Clock = std::chrono::steady_clock;
using Slots = std::map<std::string, ncnn::Mat>;
struct Binding {
    std::string slot, blob;
    int channels = 0, height = 0, width = 0;
};
struct Stage {
    std::string name, param, weights;
    std::vector<Binding> inputs, outputs;
};
struct Manifest {
    std::vector<Stage> stages;
    std::map<std::string, std::string> settings;
    std::map<std::string, std::vector<int>> shapes;
};
struct Args {
    std::string directory, bitstream, output, verify, dump, stage_only, stop_after;
    std::string input, bitstream_output;
    std::string hash_file;
    bool hash_decimal = false;
    std::vector<std::string> tensors;
    int threads = 2;
    int model_size = 0;
    float tolerance = 1e-3f;
    bool strict = false;
    bool encode = false;
    bool integers_only = false;
    bool best_effort = false;
    uint64_t stage_timeout_ms = 300000;
};
size_t recovery_events = 0;
long isolated_peak_kb = 0;
void degraded(const std::string& category, const std::string& detail) {
    ++recovery_events;
    std::string clean = detail;
    for (char& ch : clean) if (static_cast<unsigned char>(ch) < 32 || ch == 127) ch = ' ';
    std::printf("DEGRADED category=%s %s\n", category.c_str(), clean.c_str());
    std::fflush(stdout);
}
long rss_kb() {
    std::ifstream status("/proc/self/status");
    std::string line;
    while (std::getline(status, line)) if (line.compare(0, 6, "VmRSS:") == 0) {
        return std::strtol(line.c_str() + 6, nullptr, 10);
    }
    return -1;
}
long peak_kb() {
#if defined(__linux__)
    struct rusage info;
    if (!getrusage(RUSAGE_SELF, &info)) {
        long peak = std::max(info.ru_maxrss, isolated_peak_kb);
        if (!getrusage(RUSAGE_CHILDREN, &info)) peak = std::max(peak, info.ru_maxrss);
        return peak;
    }
#endif
    return -1;
}
double elapsed(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}
std::string trim(std::string text) {
    size_t first = text.find_first_not_of(" \r\n");
    return first == std::string::npos ? "" : text.substr(first, text.find_last_not_of(" \r\n") - first + 1);
}
std::vector<std::string> split(const std::string& text, char separator) {
    std::vector<std::string> result;
    std::stringstream stream(text); std::string item;
    while (std::getline(stream, item, separator)) result.push_back(trim(item));
    return result;
}
bool exists(const std::string& path) {
    FILE* file = std::fopen(path.c_str(), "rb");
    if (!file) return false;
    std::fclose(file); return true;
}
std::string join(const std::string& root, const std::string& name) {
    return root + "/" + name;
}
void safe_relative(const std::string& name) {
    if (name.empty() || name[0] == '/' || name[0] == '\\' ||
        name.find("..") != std::string::npos || name.find(':') != std::string::npos)
        throw std::runtime_error("invalid relative model path " + name);
}
void safe_slot(const std::string& name) {
    if (name.empty() || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string::npos)
        throw std::runtime_error("invalid tensor slot " + name);
}
std::vector<Binding> bindings(const std::string& text) {
    std::vector<Binding> result;
    for (auto& entry : split(text, ',')) {
        auto pair = split(entry, '=');
        if (pair.size() != 2 || pair[1].empty()) throw std::runtime_error("invalid tensor binding " + entry);
        safe_slot(pair[0]); result.push_back({pair[0], pair[1]});
    }
    return result;
}
Manifest manifest(const std::string& path) {
    std::ifstream file(path);
    if (!file) throw std::runtime_error("cannot open " + path);
    Manifest result; std::string line;
    std::map<std::string, std::map<std::string, std::vector<int>>> stage_shapes;
    while (std::getline(file, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#') continue;
        auto fields = split(line, '\t');
        if (fields[0] == "set" && fields.size() == 3) result.settings[fields[1]] = fields[2];
        else if (fields[0] == "stage" && fields.size() == 6) {
            safe_slot(fields[1]); safe_relative(fields[2]); safe_relative(fields[3]);
            Stage stage{fields[1], fields[2], fields[3], bindings(fields[4]), bindings(fields[5])};
            if (stage.inputs.empty() || stage.outputs.empty()) throw std::runtime_error("empty stage bindings");
            result.stages.push_back(stage);
        } else if ((fields[0] == "tensor" && fields.size() == 5) ||
                   (fields[0] == "stage_shape" && fields.size() == 6)) {
            bool local = fields[0] == "stage_shape";
            safe_slot(fields[1]); if (local) safe_slot(fields[2]);
            size_t offset = local ? 3 : 2;
            int c = std::stoi(fields[offset]), h = std::stoi(fields[offset + 1]), w = std::stoi(fields[offset + 2]);
            if (c < 1 || c > 8192 || h < 1 || h > 1024 || w < 1 || w > 1024)
                throw std::runtime_error("invalid CHW tensor metadata " + fields[1]);
            if (local) stage_shapes[fields[1]][fields[2]] = {c, h, w};
            else result.shapes[fields[1]] = {c, h, w};
        } else if (fields[0] == "release") {
            // Lifetime is calculated from future consumers.
        } else throw std::runtime_error("invalid manifest line in " + path + ": " + line);
    }
    for (auto& stage : result.stages) {
        auto apply = [&result](std::vector<Binding>& bindings) {
            for (auto& binding : bindings) {
                auto shape = result.shapes.find(binding.slot);
                if (shape != result.shapes.end()) {
                    binding.channels = shape->second[0];
                    binding.height = shape->second[1];
                    binding.width = shape->second[2];
                }
            }
        };
        apply(stage.inputs); apply(stage.outputs);
        for (auto& output : stage.outputs) {
            auto by_stage = stage_shapes.find(stage.name);
            if (by_stage == stage_shapes.end()) continue;
            auto shape = by_stage->second.find(output.slot);
            if (shape != by_stage->second.end()) {
                output.channels = shape->second[0]; output.height = shape->second[1]; output.width = shape->second[2];
            }
        }
    }
    return result;
}
void codec_shapes(Manifest& plan, int height, int width) {
    // These established AEIC-SE graph interfaces also support older exports.
    // Renderer shapes remain fixed by its own manifest and parameter files.
    for (auto& stage : plan.stages) {
        int c = 0, divisor = 1;
        if (stage.name == "h_s") { c = 256; divisor = 32; }
        else if (stage.name.compare(0, 3, "ctx") == 0) { c = 512; divisor = 32; }
        else if (stage.name.compare(0, 3, "g_s") == 0) {
            int block = std::stoi(stage.name.substr(3));
            if (block < 3) { c = 1024; divisor = 32; }
            else if (block < 6) { c = 768; divisor = 16; }
            else if (block < 9) { c = 512; divisor = 8; }
            else if (block == 9) { c = 576; divisor = 8; }
        } else if (stage.name.compare(0, 3, "g_a") == 0) {
            int block = std::stoi(stage.name.substr(3));
            static const int channels[] = {32,32,64,64,128,128,192,192,256,256};
            if (block >= 0 && block < 10) { c = channels[block]; divisor = 1 << (block / 2 + 1); }
        } else if (stage.name.compare(0, 3, "h_a") == 0) {
            int block = std::stoi(stage.name.substr(3));
            if (block >= 0 && block < 4) { c = 128; divisor = block == 3 ? 128 : 64; }
        }
        if (!c) continue;
        for (auto& output : stage.outputs) {
            output.channels = c; output.height = (height + divisor - 1) / divisor;
            output.width = (width + divisor - 1) / divisor;
            if (stage.name == "h_s") {
                output.height = ((height + 127) / 128) * 4;
                output.width = ((width + 127) / 128) * 4;
            } else if (stage.name.compare(0, 3, "h_a") == 0 && stage.name != "h_a3") {
                output.height = ((height + 127) / 128) * 2;
                output.width = ((width + 127) / 128) * 2;
            }
        }
    }
}
void metadata(const std::string& path, std::map<std::string, std::string>& settings) {
    if (!exists(path)) return;
    std::ifstream file(path); std::string line;
    while (std::getline(file, line)) {
        auto fields = split(trim(line), '\t');
        if (fields.empty() || fields[0].empty() || fields[0][0] == '#') continue;
        if (fields.size() == 2) settings[fields[0]] = fields[1];
        else if (fields.size() == 3 && fields[0] == "set") settings[fields[1]] = fields[2];
        else throw std::runtime_error("invalid metadata row " + line);
    }
}
int setting_int(const std::map<std::string, std::string>& values, const std::string& key, int fallback) {
    auto found = values.find(key);
    if (found == values.end()) return fallback;
    size_t used = 0; int value = std::stoi(found->second, &used);
    if (used != found->second.size() || value < 1) throw std::runtime_error("invalid setting " + key);
    return value;
}
const Stage& named(const Manifest& plan, const std::string& name) {
    const Stage* result = nullptr;
    for (auto& stage : plan.stages) if (stage.name == name) {
        if (result) throw std::runtime_error("duplicate stage " + name);
        result = &stage;
    }
    if (!result) throw std::runtime_error("missing stage " + name);
    return *result;
}
ncnn::Mat& slot(Slots& slots, const std::string& name) {
    auto found = slots.find(name);
    if (found == slots.end() || found->second.empty()) throw std::runtime_error("missing input slot " + name);
    return found->second;
}
void chw(const ncnn::Mat& tensor, int channels, int height, int width, const std::string& name) {
    if (tensor.dims != 3 || tensor.elempack != 1 || tensor.elemsize != 4 ||
        tensor.c != channels || tensor.h != height || tensor.w != width)
        throw std::runtime_error("CHW shape mismatch for " + name + ": " +
            std::to_string(tensor.c) + "x" + std::to_string(tensor.h) + "x" + std::to_string(tensor.w) +
            " expected " + std::to_string(channels) + "x" + std::to_string(height) + "x" + std::to_string(width));
}
std::vector<float> flatten(const ncnn::Mat& tensor) {
    if (tensor.elempack != 1 || tensor.elemsize != 4 || tensor.dims != 3)
        throw std::runtime_error("stage output must be float32 CHW");
    size_t plane = size_t(tensor.w) * tensor.h;
    std::vector<float> result(plane * tensor.c);
    for (int c = 0; c < tensor.c; ++c)
        std::memcpy(result.data() + c * plane, tensor.channel(c), plane * 4);
    return result;
}
void canonical_chw(ncnn::Mat& tensor, const std::string& name) {
    if (tensor.dims != 4) return;
    int channels = 0;
    if (tensor.c == 1) channels = tensor.d; // Retained batch-one NCHW axis.
    else if (tensor.d == 1) channels = tensor.c;
    else throw std::runtime_error("non-image rank4 output " + name);
    std::printf("CANONICAL_CHW %s original_c=%d original_d=%d CHW=%dx%dx%d\n",
        name.c_str(), tensor.c, tensor.d, channels, tensor.h, tensor.w);
    // Mat::reshape retains owned storage, unlike channel_range's external view.
    tensor = tensor.reshape(tensor.w, tensor.h, channels);
    if (tensor.empty()) throw std::runtime_error("cannot normalize image tensor rank " + name);
}
void check_tensor(const Args& args, const std::string& name, const ncnn::Mat& tensor) {
    auto stats = aeic::diagnose_chw(tensor);
    std::printf("TENSOR %s CHW=%dx%dx%d fnv1a64=%s range=%.7g,%.7g\n", name.c_str(),
        tensor.c, tensor.h, tensor.w, aeic::hash_hex(stats.hash).c_str(), stats.minimum, stats.maximum);
    std::string reference = join(args.verify, name + ".f32");
    bool have_reference = !args.integers_only && !args.verify.empty() && exists(reference);
    std::vector<float> values;
    if (!args.dump.empty() || have_reference) values = flatten(tensor);
    if (!args.dump.empty()) aeic::write_file(join(args.dump, name + ".f32"), values.data(), values.size() * 4);
    if (have_reference) {
      try {
        auto expected = aeic::read_floats(reference, values.size());
        double square = 0; float difference = 0;
        for (size_t i = 0; i < values.size(); ++i) {
            float delta = std::fabs(values[i] - expected[i]); difference = std::max(difference, delta); square += double(delta) * delta;
        }
        std::printf("VERIFY %s max_abs=%.9g rmse=%.9g tolerance=%.9g\n",
            name.c_str(), difference, std::sqrt(square / values.size()), args.tolerance);
        if ((args.strict || args.best_effort) && difference > args.tolerance)
            throw std::runtime_error("float reference mismatch " + name);
      } catch (const std::exception& error) {
        if (!args.best_effort) throw;
        degraded("reference", error.what());
      }
    }
    std::fflush(stdout);
}
void check_indexes(const Args& args, const std::string& name, const std::vector<int16_t>& indexes) {
    std::printf("INDEXES %s count=%zu fnv1a64=%s\n", name.c_str(), indexes.size(),
        aeic::hash_hex(aeic::hash_bytes(indexes.data(), indexes.size() * 2)).c_str());
    if (!args.dump.empty()) aeic::write_file(join(args.dump, name + ".i16"), indexes.data(), indexes.size() * 2);
    std::string reference = join(args.verify, name + ".i16");
    if (!args.verify.empty() && exists(reference)) {
      try {
        auto expected = aeic::read_indexes(reference, indexes.size());
        size_t count = 0, first = 0;
        for (size_t i = 0; i < indexes.size(); ++i) if (indexes[i] != expected[i]) { if (!count) first = i; ++count; }
        std::printf("VERIFY_INDEXES %s mismatches=%zu", name.c_str(), count);
        if (count) std::printf(" first=%zu actual=%d expected=%d", first, indexes[first], expected[first]);
        std::printf("\n"); std::fflush(stdout);
        // Index changes invalidate the existing bitstream even with small float errors.
        if (count) throw std::runtime_error("entropy indexes differ from host reference " + name);
      } catch (const std::exception& error) {
        if (!args.best_effort) throw;
        degraded("reference", error.what());
      }
    }
}
void validate_matrix_shapes(const std::string& path) {
    // ncnn Gemm treats a rank3 input's channel count as its matrix row count.
    // Detect the known pnnx batch-axis hazard before its following reshape can overread.
    std::ifstream file(path);
    if (!file) throw std::runtime_error("cannot open " + path);
    std::map<std::string, std::map<int, int>> reshapes;
    std::string line;
    while (std::getline(file, line)) {
        std::istringstream fields(line);
        std::string type, name; int inputs = 0, outputs = 0;
        if (!(fields >> type >> name >> inputs >> outputs) || inputs < 0 || outputs < 0 || inputs > 32 || outputs > 32) continue;
        std::vector<std::string> input_blobs(inputs), output_blobs(outputs);
        for (auto& blob : input_blobs) fields >> blob;
        for (auto& blob : output_blobs) fields >> blob;
        std::map<int, int> parameters; std::string text;
        while (fields >> text) {
            size_t equals = text.find('=');
            if (equals == std::string::npos || text.find(',') != std::string::npos || text.find('.') != std::string::npos) continue;
            try { parameters[std::stoi(text.substr(0, equals))] = std::stoi(text.substr(equals + 1)); }
            catch (const std::exception&) { continue; }
        }
        if (type == "Reshape" && outputs == 1) reshapes[output_blobs[0]] = parameters;
        if (type == "Gemm" && inputs > 0 && parameters[2] == 0 && parameters[4] == 0) {
            auto found = reshapes.find(input_blobs[0]);
            if (found != reshapes.end() && found->second[2] == 1 && found->second[1] > 1)
                throw std::runtime_error("unsafe batch-one rank3 input to Gemm in " + path +
                    "; export the pre-Gemm matrix as rank2 [HW,C]");
        }
    }
}
std::vector<ncnn::Mat> extract_stage(const Args& args, const Stage& stage, Slots& slots) {
    auto started = Clock::now();
    for (auto& input : stage.inputs) {
        if (input.channels)
            chw(slot(slots, input.slot), input.channels, input.height, input.width,
                stage.name + " input " + input.slot);
    }
    std::vector<ncnn::Mat> outputs(stage.outputs.size());
    {
        ncnn::Net net;
        if (aeic::register_tiled_attention(net)) throw std::runtime_error("cannot register tiled attention " + stage.name);
        net.opt.num_threads = args.threads;
        net.opt.lightmode = true;
        net.opt.use_local_pool_allocator = false;
        net.opt.blob_allocator = aeic::direct_allocator();
        net.opt.workspace_allocator = aeic::direct_allocator();
        net.opt.use_vulkan_compute = false;
        net.opt.use_packing_layout = false;
        net.opt.use_fp16_packed = false;
        net.opt.use_fp16_storage = false;
        net.opt.use_fp16_arithmetic = false;
        net.opt.use_bf16_storage = false;
        net.opt.use_winograd_convolution = false;
        net.opt.use_sgemm_convolution = false;
        validate_matrix_shapes(join(args.directory, stage.param));
        if (net.load_param(join(args.directory, stage.param).c_str())) throw std::runtime_error("load_param failed " + stage.name);
        if (net.load_model(join(args.directory, stage.weights).c_str())) throw std::runtime_error("load_model failed " + stage.name);
        std::printf("STAGE_LOADED %s seconds=%.3f rss_kb=%ld peak_kb=%ld\n", stage.name.c_str(), elapsed(started), rss_kb(), peak_kb()); std::fflush(stdout);
        auto extractor = net.create_extractor();
        extractor.set_light_mode(true);
        for (auto& input : stage.inputs)
            if (extractor.input(input.blob.c_str(), slot(slots, input.slot))) throw std::runtime_error("input failed " + stage.name + ":" + input.blob);
        // Extract all outputs before replacing a slot used by this stage's input.
        for (size_t i = 0; i < stage.outputs.size(); ++i) {
            if (extractor.extract(stage.outputs[i].blob.c_str(), outputs[i])) throw std::runtime_error("extract failed " + stage.name + ":" + stage.outputs[i].blob);
            if (outputs[i].empty()) throw std::runtime_error("empty output " + stage.name);
            canonical_chw(outputs[i], stage.name + "." + stage.outputs[i].slot);
            if (stage.outputs[i].channels)
                chw(outputs[i], stage.outputs[i].channels, stage.outputs[i].height, stage.outputs[i].width,
                    stage.name + " output " + stage.outputs[i].slot);
        }
    }
    // Extracted Mats own their storage after the graph and its allocators die.
    return outputs;
}
ncnn::Mat owned_tensor(aeic_recovery::Shape shape, const float* values, size_t elements) {
    size_t expected = 0; std::string reason;
    if (!values || !aeic_recovery::checked_elements(shape, 256u << 20, expected, reason) || expected != elements)
        throw std::runtime_error("invalid shared recovery output");
    ncnn::Mat output(shape.w, shape.h, shape.c);
    if (output.empty()) throw std::runtime_error("cannot allocate recovered stage output");
    size_t plane = size_t(shape.h) * shape.w;
    for (int c = 0; c < shape.c; ++c)
        std::memcpy(output.channel(c), values + c * plane, plane * sizeof(float));
    return output;
}
ncnn::Mat fallback_tensor(const Stage& stage, Slots& slots, std::string& strategy) {
    const auto& shape = stage.outputs.at(0);
    size_t elements = 0; std::string reason;
    if (!aeic_recovery::checked_elements({shape.channels, shape.height, shape.width}, 256u << 20, elements, reason))
        throw std::runtime_error("cannot create bounded stage fallback: " + reason);
    const ncnn::Mat* resize_source = nullptr;
    for (const auto& input : stage.inputs) {
        auto found = slots.find(input.slot);
        if (found == slots.end() || found->second.empty()) continue;
        const auto& source = found->second;
        if (source.dims != 3 || source.elempack != 1 || source.elemsize != 4 || source.c != shape.channels) continue;
        try { aeic::diagnose_chw(source); } catch (const std::exception&) { continue; }
        if (source.h == shape.height && source.w == shape.width) {
            strategy = "preserve"; return source;
        }
        if (!resize_source) resize_source = &source;
    }
    ncnn::Mat output(shape.width, shape.height, shape.channels);
    if (output.empty()) throw std::runtime_error("cannot allocate fallback tensor");
    if (!resize_source) { output.fill(0.f); strategy = "zeros"; return output; }
    strategy = "nearest_resize";
    for (int c = 0; c < shape.channels; ++c) {
        const float* source = resize_source->channel(c); float* target = output.channel(c);
        for (int h = 0; h < shape.height; ++h) for (int w = 0; w < shape.width; ++w)
            target[size_t(h) * shape.width + w] = source[size_t(h) * resize_source->h / shape.height * resize_source->w +
                size_t(w) * resize_source->w / shape.width];
    }
    return output;
}
void execute(const Args& args, const Stage& stage, Slots& slots) {
    auto started = Clock::now();
    std::printf("STAGE_BEGIN %s rss_kb=%ld peak_kb=%ld isolated=%s\n",
        stage.name.c_str(), rss_kb(), peak_kb(), args.best_effort ? "true" : "false"); std::fflush(stdout);
    std::vector<ncnn::Mat> outputs;
    if (!args.best_effort) outputs = extract_stage(args, stage, slots);
    else {
        if (stage.outputs.size() != 1 || !stage.outputs[0].channels)
            throw std::runtime_error("best-effort requires one output with known CHW metadata: " + stage.name);
        const auto& shape = stage.outputs[0];
        aeic_recovery::Options options; options.timeout_ms = args.stage_timeout_ms;
        options.max_output_bytes = 256u << 20;
        // This trusted callback validates and copies every logical element.
        // Touch IPC pages only after model weights/intermediates are released.
        options.initialize_output = false;
        auto shared = aeic_recovery::run_isolated_shared({shape.channels, shape.height, shape.width}, options, [&](float* target, size_t count) {
            auto extracted = extract_stage(args, stage, slots);
            const auto& output = extracted.at(0);
            size_t plane = size_t(output.h) * output.w;
            if (output.dims != 3 || output.elempack != 1 || output.elemsize != 4 || plane * output.c != count)
                throw std::runtime_error("invalid shared stage output layout");
            // Net is destroyed. Copy logical CHW directly into IPC without a
            // vector, respecting any ncnn channel-stride alignment padding.
            for (int c = 0; c < output.c; ++c)
                std::memcpy(target + c * plane, output.channel(c), plane * sizeof(float));
        });
        const auto& result = shared.result;
        isolated_peak_kb = std::max(isolated_peak_kb, static_cast<long>(std::min<uint64_t>(result.child_peak_kb, std::numeric_limits<long>::max())));
        std::printf("STAGE_ISOLATED %s status=%s child_peak_kb=%llu parent_rss_kb=%ld\n",
            stage.name.c_str(), aeic_recovery::status_name(result.status), static_cast<unsigned long long>(result.child_peak_kb), rss_kb());
        if (result.ok()) {
            outputs.push_back(owned_tensor(shared.shape, shared.values, shared.elements));
            shared.owner.reset();
        }
        else {
            std::string strategy;
            outputs.push_back(fallback_tensor(stage, slots, strategy));
            degraded("model", "stage=" + stage.name + " status=" + aeic_recovery::status_name(result.status) +
                " signal=" + std::to_string(result.signal) + " exit=" + std::to_string(result.exit_code) +
                " fallback=" + strategy + " reason=" + result.reason);
        }
    }
    for (size_t i = 0; i < outputs.size(); ++i) {
        check_tensor(args, stage.name + "." + stage.outputs[i].slot, outputs[i]);
        slots[stage.outputs[i].slot] = outputs[i];
    }
    std::printf("STAGE_END %s seconds=%.3f rss_kb=%ld peak_kb=%ld\n", stage.name.c_str(), elapsed(started), rss_kb(), peak_kb()); std::fflush(stdout);
}
void release_unused(Slots& slots, const std::vector<Stage>& stages, size_t next,
                    const std::set<std::string>& preserve) {
    std::set<std::string> needed = preserve;
    for (size_t i = next; i < stages.size(); ++i)
        for (auto& input : stages[i].inputs) needed.insert(input.slot);
    for (auto it = slots.begin(); it != slots.end();) {
        if (!needed.count(it->first)) it = slots.erase(it); else ++it;
    }
}
void crop_base(ncnn::Mat& base, int channels, int height, int width) {
    if (base.w == width && base.h == height) { chw(base, channels, height, width, "base"); return; }
    if (base.dims != 3 || base.c != channels || base.w < width || base.h < height || base.elempack != 1 || base.elemsize != 4)
        throw std::runtime_error("invalid hyper synthesis output shape");
    ncnn::Mat cropped(width, height, channels);
    if (cropped.empty()) throw std::runtime_error("cannot allocate cropped base");
    for (int c = 0; c < channels; ++c) {
        const float* source = base.channel(c); float* target = cropped.channel(c);
        for (int h = 0; h < height; ++h) std::memcpy(target + h * width, source + h * base.w, width * 4);
    }
    base = cropped;
}
bool stop(const Args& args, const std::string& name) {
    if (args.stop_after != name) return false;
    std::printf("PARTIAL_TEST stopped_after=%s full_decode=false\n", name.c_str());
    std::printf("RESULT_STATUS degraded=%s recovery_events=%zu child_peak_kb=%ld\n",
        recovery_events ? "true" : "false", recovery_events, isolated_peak_kb);
    std::fflush(stdout); return true;
}
bool decode_codec(const Args& args, const Manifest& plan, const aeic::Bitstream& stream, Slots& slots) {
    int channels = setting_int(plan.settings, "y_channels", 256);
    if (channels != 256) throw std::runtime_error("this prototype requires AEIC-SE 256 latent channels");
    int y_h = ((stream.height + 63) / 64) * 2, y_w = ((stream.width + 63) / 64) * 2;
    int z_h = (y_h + 3) / 4, z_w = (y_w + 3) / 4;
    int configured_h = setting_int(plan.settings, "input_height", int(stream.height));
    int configured_w = setting_int(plan.settings, "input_width", int(stream.width));
    if (configured_h != int(stream.height) || configured_w != int(stream.width))
        throw std::runtime_error("bitstream dimensions differ from exported fixed-shape models");
    std::unique_ptr<aeic::EntropyDecoder> entropy;
    int z_group = -1, y_group = -1;
    try {
        auto z_cdf = aeic::read_cdf(join(args.directory, "z_cdf.bin"));
        auto y_cdf = aeic::read_cdf(join(args.directory, "y_cdf.bin"));
        if (z_cdf.cdf->size() != size_t(channels / 2) || y_cdf.cdf->size() != 64)
            throw std::runtime_error("AEIC-SE entropy table row count mismatch");
        entropy.reset(new aeic::EntropyDecoder(stream, args.best_effort));
        z_group = entropy->add_cdf(z_cdf); y_group = entropy->add_cdf(y_cdf);
    } catch (const std::exception& error) {
        if (!args.best_effort) throw;
        entropy.reset(); degraded("entropy", std::string(error.what()) + "; all symbols replaced by zeros");
    }
    auto entropy_notes = [&]() {
        if (entropy) for (const auto& warning : entropy->take_warnings()) degraded("entropy", warning);
    };
    entropy_notes();
    auto decode_symbols = [&](const std::vector<int16_t>& indexes, int group) {
        auto values = entropy ? entropy->decode(indexes, group) : std::vector<int16_t>(indexes.size(), 0);
        entropy_notes(); return values;
    };
    std::vector<float> medians(channels / 2, 0.f);
    try { medians = aeic::read_floats(join(args.directory, "z_medians.f32"), channels / 2); }
    catch (const std::exception& error) {
        if (!args.best_effort) throw;
        degraded("model", std::string(error.what()) + "; hyperprior medians replaced by zeros");
    }
    size_t z_plane = size_t(z_h) * z_w;
    std::vector<int16_t> z_indexes(z_plane * (channels / 2));
    for (int c = 0; c < channels / 2; ++c) std::fill(z_indexes.begin() + c * z_plane, z_indexes.begin() + (c + 1) * z_plane, c);
    auto z_symbols = decode_symbols(z_indexes, z_group);
    check_indexes(args, "z_symbols", z_symbols);
    ncnn::Mat z_hat(z_w, z_h, channels / 2);
    if (z_hat.empty()) throw std::runtime_error("cannot allocate z_hat");
    for (int c = 0; c < channels / 2; ++c) {
        float* target = z_hat.channel(c);
        for (size_t p = 0; p < z_plane; ++p) target[p] = z_symbols[c * z_plane + p] + medians[c];
    }
    slots["z_hat"] = z_hat; check_tensor(args, "z_hat", z_hat);
    if (stop(args, "z_hat")) return false;
    execute(args, named(plan, "h_s"), slots);
    slots.erase("z_hat"); z_hat.release();
    crop_base(slot(slots, "base"), channels, y_h, y_w);
    if (stop(args, "h_s")) return false;
    size_t plane = size_t(y_h) * y_w;
    int quarter = channels / 4;
    for (int round = 0; round < 4; ++round) {
        execute(args, named(plan, "ctx" + std::to_string(round)), slots);
        auto& prediction = slot(slots, "means_scales");
        chw(prediction, channels * 2, y_h, y_w, "means_scales");
        std::vector<int16_t> indexes(quarter * plane);
        std::vector<float> means(quarter * plane);
        for (int c = 0; c < quarter; ++c) for (int h = 0; h < y_h; ++h) for (int w = 0; w < y_w; ++w) {
            int quadrant = (h & 1) * 2 + (w & 1), group = 0;
            while (aeic::mask_quadrant(round, group) != quadrant) ++group;
            int original_c = group * quarter + c; size_t p = size_t(h) * y_w + w;
            const float* mean = prediction.channel(original_c);
            const float* scale = prediction.channel(channels + original_c);
            indexes[c * plane + p] = aeic::scale_index(scale[p]);
            means[c * plane + p] = mean[p];
        }
        std::string round_name = "y" + std::to_string(round);
        check_indexes(args, round_name + "_indices", indexes);
        auto symbols = decode_symbols(indexes, y_group);
        check_indexes(args, round_name + "_symbols", symbols);
        auto& base = slot(slots, "base");
        for (int c = 0; c < quarter; ++c) for (int h = 0; h < y_h; ++h) for (int w = 0; w < y_w; ++w) {
            int quadrant = (h & 1) * 2 + (w & 1), group = 0;
            while (aeic::mask_quadrant(round, group) != quadrant) ++group;
            float* channel = base.channel(group * quarter + c); size_t p = size_t(h) * y_w + w;
            channel[p] = symbols[c * plane + p] + means[c * plane + p];
        }
        slots.erase("means_scales");
        if (stop(args, "ctx" + std::to_string(round))) return false;
    }
    if (entropy) { entropy->verify_complete(); entropy_notes(); }
    if (entropy && entropy->fully_complete())
        std::printf("ENTROPY_COMPLETE two_streams=true terminal_states=8388608 bytes_remaining=0\n");
    else std::printf("ENTROPY_DEGRADED terminal_verified=false unavailable_symbols=zeros\n");
    std::fflush(stdout);
    slots["y_hat"] = slot(slots, "base"); slots.erase("base");
    check_tensor(args, "y_hat", slot(slots, "y_hat"));
    if (stop(args, "y_hat")) return false;
    std::vector<Stage> synthesis;
    for (auto& stage : plan.stages) if (stage.name.compare(0, 3, "g_s") == 0) synthesis.push_back(stage);
    if (synthesis.empty()) throw std::runtime_error("missing codec synthesis stages");
    for (size_t i = 0; i < synthesis.size(); ++i) {
        execute(args, synthesis[i], slots);
        release_unused(slots, synthesis, i + 1, {"synthesis", "l_T", "residual"});
        if (stop(args, synthesis[i].name)) return false;
    }
    auto combined = slots.find("synthesis");
    if (combined != slots.end()) {
        const auto& tensor = combined->second;
        chw(tensor, 576, y_h * 4, y_w * 4, "synthesis");
        // channel_range borrows external data; clone before releasing its owner.
        slots["l_T"] = tensor.channel_range(0, 320).clone();
        slots["residual"] = tensor.channel_range(320, 256).clone();
        if (slot(slots, "l_T").empty() || slot(slots, "residual").empty())
            throw std::runtime_error("cannot allocate owning synthesis outputs");
        slots.erase("synthesis");
    }
    check_tensor(args, "l_T", slot(slots, "l_T"));
    check_tensor(args, "residual", slot(slots, "residual"));
    return true;
}
struct InputImage {
    int height, width;
    ncnn::Mat pixels;
};
InputImage read_ppm(const std::string& path) {
    auto bytes = aeic::read_file(path, 4u << 20);
    size_t cursor = 0;
    auto token = [&bytes, &cursor]() {
        while (cursor < bytes.size()) {
            if (std::isspace(static_cast<unsigned char>(bytes[cursor]))) { ++cursor; continue; }
            if (bytes[cursor] == '#') {
                while (cursor < bytes.size() && bytes[cursor] != '\n') ++cursor;
                continue;
            }
            break;
        }
        size_t first = cursor;
        while (cursor < bytes.size() && !std::isspace(static_cast<unsigned char>(bytes[cursor])) && bytes[cursor] != '#') ++cursor;
        if (first == cursor || cursor - first > 32) throw std::runtime_error("invalid PPM header");
        return std::string(bytes.begin() + first, bytes.begin() + cursor);
    };
    if (token() != "P6") throw std::runtime_error("--input requires an RGB P6 PPM file");
    auto integer = [](const std::string& text) {
        size_t count = 0; int value = std::stoi(text, &count);
        if (count != text.size() || value <= 0) throw std::runtime_error("invalid PPM dimensions");
        return value;
    };
    int width = integer(token()), height = integer(token());
    auto supported_size = [](int size) { return size >= 128 && size <= 576 && size % 64 == 0; };
    if (!supported_size(width) || !supported_size(height))
        throw std::runtime_error("native encoder requires dimensions from 128 through 576 divisible by 64");
    if (integer(token()) != 255) throw std::runtime_error("PPM must contain 8-bit RGB samples (maxval 255)");
    if (cursor == bytes.size() || !std::isspace(static_cast<unsigned char>(bytes[cursor])))
        throw std::runtime_error("PPM header has no binary separator");
    // Consume exactly the header separator; pixel bytes may themselves be whitespace.
    if (bytes[cursor] == '\r' && cursor + 1 < bytes.size() && bytes[cursor + 1] == '\n') cursor += 2;
    else ++cursor;
    if (bytes.size() - cursor != size_t(height) * width * 3)
        throw std::runtime_error("PPM pixel byte count mismatch");
    ncnn::Mat tensor(width, height, 3);
    if (tensor.empty()) throw std::runtime_error("cannot allocate RGB encoder input");
    for (int c = 0; c < 3; ++c) {
        float* channel = tensor.channel(c);
        for (size_t p = 0; p < size_t(width) * height; ++p) {
            // Match torchvision ToTensor, then Normalize(mean=.5, std=.5).
            float value = static_cast<float>(bytes[cursor + p * 3 + c]) / 255.f;
            channel[p] = (value - .5f) / .5f;
        }
    }
    return {height, width, tensor};
}
int16_t rounded_symbol(float value, bool best_effort, size_t& repaired) {
    if (!std::isfinite(value)) {
        if (!best_effort) throw std::runtime_error("nonfinite encoder latent");
        ++repaired; return 0;
    }
    float rounded = std::nearbyint(value);
    if (rounded < -32768.f || rounded > 32767.f) {
        if (!best_effort) throw std::runtime_error("encoder symbol outside int16 range");
        ++repaired; rounded = std::max(-32768.f, std::min(32767.f, rounded));
    }
    return static_cast<int16_t>(rounded);
}
bool encode_image(const Args& args, const Manifest& codec, Slots& slots) {
    auto started = Clock::now();
    if (std::fesetround(FE_TONEAREST)) throw std::runtime_error("cannot select ties-to-even rounding");
    auto image = read_ppm(args.input);
    if (setting_int(codec.settings, "input_height", image.height) != image.height ||
        setting_int(codec.settings, "input_width", image.width) != image.width)
        throw std::runtime_error("PPM dimensions differ from exported model metadata");
    int channels = setting_int(codec.settings, "y_channels", 256);
    if (channels != 256) throw std::runtime_error("native encoder requires AEIC-SE");
    std::printf("ENCODE_BEGIN height=%d width=%d threads=%d rss_kb=%ld input=%s\n",
        image.height, image.width, args.threads, rss_kb(), args.input.c_str()); std::fflush(stdout);
    Manifest encoder_plan = manifest(join(args.directory, "encoder.tsv"));
    codec_shapes(encoder_plan, image.height, image.width);
    if (encoder_plan.stages.empty()) throw std::runtime_error("encoder manifest has no stages");
    slots["x"] = image.pixels; image.pixels.release();
    check_tensor(args, "encode_x", slot(slots, "x"));
    for (size_t i = 0; i < encoder_plan.stages.size(); ++i) {
        ncnn::Mat unpadded_y;
        if (encoder_plan.stages[i].name == "h_a0") {
            const auto& original = slot(slots, "y");
            int padded_h = ((original.h + 3) / 4) * 4, padded_w = ((original.w + 3) / 4) * 4;
            if (padded_h != original.h || padded_w != original.w) {
                ncnn::Mat padded(padded_w, padded_h, original.c);
                if (padded.empty()) throw std::runtime_error("cannot allocate hyper-analysis padded input");
                padded.fill(0.f);
                bool reflect = padded_h - original.h < original.h && padded_w - original.w < original.w;
                for (int c = 0; c < original.c; ++c) {
                    const float* source = original.channel(c); float* target = padded.channel(c);
                    if (reflect) {
                        for (int h = 0; h < padded_h; ++h) for (int w = 0; w < padded_w; ++w) {
                            int reflected_h = h < original.h ? h : 2 * original.h - h - 2;
                            int reflected_w = w < original.w ? w : 2 * original.w - w - 2;
                            target[h * padded_w + w] = source[reflected_h * original.w + reflected_w];
                        }
                    } else {
                        for (int h = 0; h < original.h; ++h)
                            std::memcpy(target + h * padded_w, source + h * original.w, size_t(original.w) * 4);
                    }
                }
                // Match the official inference zero pad. Reflect padding by two
                // pixels is undefined for the 64px image's 2x2 latent.
                std::printf("HYPER_PADDING mode=%s latent=%dx%d padded=%dx%d\n",
                    reflect ? "reflect" : "constant_zero", original.h, original.w, padded_h, padded_w);
                unpadded_y = original; slots["y"] = padded;
            }
        }
        execute(args, encoder_plan.stages[i], slots);
        if (!unpadded_y.empty()) slots["y"] = unpadded_y;
        release_unused(slots, encoder_plan.stages, i + 1, {"y", "z"});
        if (stop(args, encoder_plan.stages[i].name)) return false;
    }
    int y_h = image.height / 32, y_w = image.width / 32;
    int z_h = (y_h + 3) / 4, z_w = (y_w + 3) / 4;
    chw(slot(slots, "y"), channels, y_h, y_w, "encoder y");
    chw(slot(slots, "z"), channels / 2, z_h, z_w, "encoder z");
    auto z_cdf = aeic::read_cdf(join(args.directory, "z_cdf.bin"));
    auto y_cdf = aeic::read_cdf(join(args.directory, "y_cdf.bin"));
    if (z_cdf.cdf->size() != size_t(channels / 2) || y_cdf.cdf->size() != 64)
        throw std::runtime_error("AEIC-SE encoder CDF row mismatch");
    aeic::EntropyEncoder entropy;
    int z_group = entropy.add_cdf(z_cdf), y_group = entropy.add_cdf(y_cdf);
    std::vector<float> medians(channels / 2, 0.f);
    try { medians = aeic::read_floats(join(args.directory, "z_medians.f32"), channels / 2); }
    catch (const std::exception& error) {
        if (!args.best_effort) throw;
        degraded("model", std::string(error.what()) + "; encoder hyperprior medians replaced by zeros");
    }
    size_t z_plane = size_t(z_h) * z_w;
    std::vector<int16_t> z_indexes(z_plane * (channels / 2)), z_symbols(z_indexes.size());
    ncnn::Mat z_hat(z_w, z_h, channels / 2);
    if (z_hat.empty()) throw std::runtime_error("cannot allocate encoder z_hat");
    size_t z_repaired = 0;
    for (int c = 0; c < channels / 2; ++c) {
        const float* source = slot(slots, "z").channel(c); float* target = z_hat.channel(c);
        for (size_t p = 0; p < z_plane; ++p) {
            z_indexes[c * z_plane + p] = c;
            int16_t symbol = rounded_symbol(source[p] - medians[c], args.best_effort, z_repaired);
            z_symbols[c * z_plane + p] = symbol;
            target[p] = static_cast<float>(symbol) + medians[c];
        }
    }
    if (z_repaired) degraded("entropy", "encoder z symbols outside representable range repaired count=" + std::to_string(z_repaired));
    check_indexes(args, "encode_z_indices", z_indexes);
    check_indexes(args, "encode_z_symbols", z_symbols);
    entropy.encode(z_symbols, z_indexes, z_group);
    slots.erase("z"); slots["z_hat"] = z_hat; z_hat.release();
    execute(args, named(codec, "h_s"), slots);
    slots.erase("z_hat");
    crop_base(slot(slots, "base"), channels, y_h, y_w);
    size_t plane = size_t(y_h) * y_w;
    int quarter = channels / 4;
    for (int round = 0; round < 4; ++round) {
        execute(args, named(codec, "ctx" + std::to_string(round)), slots);
        auto& prediction = slot(slots, "means_scales");
        chw(prediction, channels * 2, y_h, y_w, "encoder means_scales");
        std::vector<int16_t> indexes(quarter * plane), symbols(indexes.size());
        std::vector<float> means(indexes.size());
        size_t skipped_nonzero = 0;
        size_t repaired = 0;
        for (int c = 0; c < quarter; ++c) for (int h = 0; h < y_h; ++h) for (int w = 0; w < y_w; ++w) {
            int quadrant = (h & 1) * 2 + (w & 1), group = 0;
            while (aeic::mask_quadrant(round, group) != quadrant) ++group;
            int original_c = group * quarter + c; size_t p = size_t(h) * y_w + w;
            const float* mean = prediction.channel(original_c);
            const float* scale = prediction.channel(channels + original_c);
            const float* latent = slot(slots, "y").channel(original_c);
            size_t index = c * plane + p;
            indexes[index] = aeic::scale_index(scale[p]);
            means[index] = mean[p];
            symbols[index] = rounded_symbol(latent[p] - mean[p], args.best_effort, repaired);
            if (indexes[index] < 0 && symbols[index] != 0) ++skipped_nonzero;
        }
        std::string name = "encode_y" + std::to_string(round);
        if (repaired) degraded("entropy", "encoder round=" + std::to_string(round) +
            " symbols outside representable range repaired count=" + std::to_string(repaired));
        if (skipped_nonzero) {
            if (!args.best_effort) throw std::runtime_error("encoder produced " + std::to_string(skipped_nonzero) +
                " nonzero symbols at skipped entropy indexes in round " + std::to_string(round));
            for (size_t i = 0; i < indexes.size(); ++i) if (indexes[i] < 0) symbols[i] = 0;
            degraded("entropy", "encode round=" + std::to_string(round) + " skipped nonzero symbols forced to zero count=" + std::to_string(skipped_nonzero));
        }
        check_indexes(args, name + "_indices", indexes);
        check_indexes(args, name + "_symbols", symbols);
        entropy.encode(symbols, indexes, y_group);
        if (round < 3) {
            auto& base = slot(slots, "base");
            for (int c = 0; c < quarter; ++c) for (int h = 0; h < y_h; ++h) for (int w = 0; w < y_w; ++w) {
                int quadrant = (h & 1) * 2 + (w & 1), group = 0;
                while (aeic::mask_quadrant(round, group) != quadrant) ++group;
                float* target = base.channel(group * quarter + c); size_t p = size_t(h) * y_w + w;
                target[p] = static_cast<float>(symbols[c * plane + p]) + means[c * plane + p];
            }
        }
        slots.erase("means_scales");
        if (stop(args, "ctx" + std::to_string(round))) return false;
    }
    auto bytes = entropy.finish(image.height, image.width);
    aeic::write_file(args.bitstream_output, bytes.data(), bytes.size());
    std::printf("ENCODE_COMPLETE height=%d width=%d bytes=%zu bpp=%.6f seconds=%.3f rss_kb=%ld peak_kb=%ld aeic_fnv1a64=%s output=%s\n",
        image.height, image.width, bytes.size(), double(bytes.size()) * 8 / (image.height * image.width),
        elapsed(started), rss_kb(), peak_kb(), aeic::hash_hex(aeic::hash_bytes(bytes.data(), bytes.size())).c_str(), args.bitstream_output.c_str());
    std::printf("RESULT_STATUS degraded=%s recovery_events=%zu child_peak_kb=%ld\n",
        recovery_events ? "true" : "false", recovery_events, isolated_peak_kb);
    std::fflush(stdout); return true;
}
void ppm(const std::string& path, const ncnn::Mat& rgb, int height, int width,
         const std::string& range) {
    if (rgb.dims != 3 || rgb.c != 3 || rgb.w < width || rgb.h < height || rgb.elempack != 1 || rgb.elemsize != 4)
        throw std::runtime_error("invalid RGB output tensor");
    if (range != "-1,1" && range != "0,1") throw std::runtime_error("unsupported rgb_range " + range);
    std::vector<uint8_t> pixels(size_t(width) * height * 3);
    for (int h = 0; h < height; ++h) {
        for (int w = 0; w < width; ++w) for (int c = 0; c < 3; ++c) {
            const float* plane = rgb.channel(c); float value = plane[h * rgb.w + w];
            if (!std::isfinite(value)) throw std::runtime_error("nonfinite RGB value");
            if (range == "-1,1") value = value * .5f + .5f;
            // Match torchvision ToPILImage float -> uint8 conversion (truncation).
            pixels[(size_t(h) * width + w) * 3 + c] = static_cast<uint8_t>(std::min(1.f, std::max(0.f, value)) * 255.f);
        }
    }
    std::string extension = path.size() >= 4 ? path.substr(path.size() - 4) : "";
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    if (extension == ".png") {
        auto bytes = aeic::make_png(width, height, pixels);
        aeic::write_file(path, bytes.data(), bytes.size());
    } else {
        std::string header = "P6\n" + std::to_string(width) + " " + std::to_string(height) + "\n255\n";
        std::vector<uint8_t> bytes(header.begin(), header.end());
        bytes.insert(bytes.end(), pixels.begin(), pixels.end());
        aeic::write_file(path, bytes.data(), bytes.size());
    }
}
std::string canonical(const std::string& path) {
#if defined(_WIN32)
    char* raw = _fullpath(nullptr, path.c_str(), 0);
#else
    char* raw = realpath(path.c_str(), nullptr);
#endif
    if (!raw) throw std::runtime_error("cannot resolve directory " + path);
    std::string resolved(raw); std::free(raw);
#if defined(_WIN32)
    std::transform(resolved.begin(), resolved.end(), resolved.begin(), [](unsigned char c) { return char(std::tolower(c)); });
#endif
    return resolved;
}
void inject(const std::string& spec, Slots& slots) {
    // --tensor slot=C,H,W:path.f32 is a diagnostics-only stage input.
    size_t equals = spec.find('='), colon = spec.find(':', equals == std::string::npos ? 0 : equals + 1);
    if (equals == std::string::npos || colon == std::string::npos) throw std::runtime_error("invalid --tensor spec");
    std::string name = spec.substr(0, equals); safe_slot(name);
    auto dimensions = split(spec.substr(equals + 1, colon - equals - 1), ',');
    if (dimensions.size() != 3) throw std::runtime_error("--tensor expects C,H,W");
    int c = std::stoi(dimensions[0]), h = std::stoi(dimensions[1]), w = std::stoi(dimensions[2]);
    if (c < 1 || c > 8192 || h < 1 || h > 1024 || w < 1 || w > 1024 || uint64_t(c) * h * w > (32u << 20))
        throw std::runtime_error("invalid --tensor shape");
    auto values = aeic::read_floats(spec.substr(colon + 1), size_t(c) * h * w);
    ncnn::Mat tensor(w, h, c);
    if (tensor.empty()) throw std::runtime_error("cannot allocate diagnostic input");
    for (int channel = 0; channel < c; ++channel)
        std::memcpy(tensor.channel(channel), values.data() + size_t(channel) * h * w, size_t(h) * w * 4);
    slots[name] = tensor;
}
Args arguments(int argc, char** argv) {
    Args result;
    for (int i = 1; i < argc; ++i) {
        std::string key = argv[i];
        if (key == "--encode") { result.encode = true; continue; }
        if (key == "--verify-integers-only") { result.integers_only = true; continue; }
        if (key == "--strict-verify") { result.strict = true; continue; }
        if (key == "--best-effort") { result.best_effort = true; continue; }
        if (key == "--hash-decimal") { result.hash_decimal = true; continue; }
        if (key == "--help") {
            std::printf("aeic_decode --model-dir DIR --bitstream FILE --output FILE.png|FILE.ppm\n"
                "aeic_decode --encode --model-dir DIR --input FILE.ppm --bitstream-output FILE.aeic\n"
                "  [--threads 1..4] [--verify-dir DIR] [--dump-dir DIR]\n"
                "  [--strict-verify] [--verify-tolerance FLOAT] [--stop-after STAGE]\n"
                "  [--verify-integers-only] (skip optional float references)\n"
                "  [--model-size N] (128..576, divisible by 64; override codec metadata)\n"
                "  [--best-effort] [--stage-timeout-ms N] (recover with DEGRADED warnings)\n"
                "Diagnostics only: --stage-only NAME --tensor SLOT=C,H,W:FILE.f32\n");
            std::printf("File integrity: aeic_decode --hash-file FILE [--hash-decimal]\n");
            std::exit(0);
        }
        if (++i == argc) throw std::runtime_error("missing value for " + key);
        std::string value = argv[i];
        if (key == "--model-dir") result.directory = value;
        else if (key == "--bitstream") result.bitstream = value;
        else if (key == "--output") result.output = value;
        else if (key == "--input") result.input = value;
        else if (key == "--bitstream-output") result.bitstream_output = value;
        else if (key == "--hash-file") result.hash_file = value;
        else if (key == "--verify-dir") result.verify = value;
        else if (key == "--dump-dir") result.dump = value;
        else if (key == "--threads") result.threads = std::stoi(value);
        else if (key == "--model-size") result.model_size = std::stoi(value);
        else if (key == "--stage-timeout-ms") result.stage_timeout_ms = std::stoull(value);
        else if (key == "--verify-tolerance") result.tolerance = std::stof(value);
        else if (key == "--stage-only") result.stage_only = value;
        else if (key == "--stop-after") result.stop_after = value;
        else if (key == "--tensor") result.tensors.push_back(value);
        else throw std::runtime_error("unknown argument " + key);
    }
    if (!result.hash_file.empty()) return result;
    if (result.directory.empty()) throw std::runtime_error("--model-dir is required");
    if (result.threads < 1 || result.threads > 4 || !std::isfinite(result.tolerance) || result.tolerance < 0)
        throw std::runtime_error("invalid thread count or verification tolerance");
    if (result.model_size && (result.model_size < 128 || result.model_size > 576 || result.model_size % 64))
        throw std::runtime_error("--model-size must be 128..576 and divisible by 64");
    if (!result.stage_timeout_ms || result.stage_timeout_ms > 3600000)
        throw std::runtime_error("--stage-timeout-ms must be 1..3600000");
    if (result.encode && (!result.stage_only.empty() || result.input.empty() || result.bitstream_output.empty()))
        throw std::runtime_error("encode requires --input and --bitstream-output and cannot use --stage-only");
    if (!result.encode && result.stage_only.empty() && (result.bitstream.empty() || (result.output.empty() && result.stop_after.empty())))
        throw std::runtime_error("--bitstream and --output are required for decode");
    if (result.stage_only.empty() && !result.tensors.empty())
        throw std::runtime_error("raw tensor injection is allowed only with --stage-only diagnostics");
    if (!result.dump.empty() && !result.verify.empty() && canonical(result.dump) == canonical(result.verify))
        throw std::runtime_error("--dump-dir and --verify-dir must be different canonical directories");
    return result;
}
}

int main(int argc, char** argv) {
    try {
        Args args = arguments(argc, argv);
        if (!args.hash_file.empty()) {
            const auto hash = aeic::hash_file_streamed(args.hash_file);
            std::printf("HASH_FILE bytes=%llu fnv1a64=%s", static_cast<unsigned long long>(hash.bytes),
                aeic::hash_hex(hash.fnv1a64).c_str());
            if (args.hash_decimal) std::printf(" fnv1a64_decimal=%llu", static_cast<unsigned long long>(hash.fnv1a64));
            std::printf(" path=%s\n", args.hash_file.c_str());
            return 0;
        }
        if (args.integers_only) std::printf("VERIFY_MODE exact_integer_references_only=true float_references=false\n");
        if (args.best_effort) std::printf("RECOVERY_MODE enabled=true isolated_model_stages=true fallback_may_change_image=true\n");
        auto started = Clock::now();
        Manifest codec = manifest(join(args.directory, "codec.tsv"));
        metadata(join(args.directory, "metadata.tsv"), codec.settings);
        if (args.model_size) {
            codec.settings["input_height"] = std::to_string(args.model_size);
            codec.settings["input_width"] = std::to_string(args.model_size);
        }
        auto valid_model_size = [](int size) { return size >= 128 && size <= 576 && size % 64 == 0; };
        if (!valid_model_size(setting_int(codec.settings, "input_height", 256)) ||
            !valid_model_size(setting_int(codec.settings, "input_width", 256)))
            throw std::runtime_error("model metadata dimensions must be 128..576 divisible by 64");
        codec_shapes(codec, setting_int(codec.settings, "input_height", 256), setting_int(codec.settings, "input_width", 256));
        Slots slots;
        if (args.encode) {
            encode_image(args, codec, slots);
            return 0;
        }
        if (!args.stage_only.empty()) {
            Manifest renderer;
            if (exists(join(args.directory, "renderer.tsv"))) renderer = manifest(join(args.directory, "renderer.tsv"));
            for (auto& spec : args.tensors) inject(spec, slots);
            const Stage* stage = nullptr;
            for (auto& candidate : codec.stages) if (candidate.name == args.stage_only) stage = &candidate;
            for (auto& candidate : renderer.stages) if (candidate.name == args.stage_only) stage = &candidate;
            Manifest encoder_plan;
            if (exists(join(args.directory, "encoder.tsv"))) encoder_plan = manifest(join(args.directory, "encoder.tsv"));
            codec_shapes(encoder_plan, setting_int(codec.settings, "input_height", 256), setting_int(codec.settings, "input_width", 256));
            for (auto& candidate : encoder_plan.stages) if (candidate.name == args.stage_only) stage = &candidate;
            if (!stage) throw std::runtime_error("unknown diagnostic stage " + args.stage_only);
            execute(args, *stage, slots);
            std::printf("STAGE_TEST_COMPLETE full_decode=false seconds=%.3f peak_kb=%ld\n", elapsed(started), peak_kb());
            std::printf("RESULT_STATUS degraded=%s recovery_events=%zu child_peak_kb=%ld\n",
                recovery_events ? "true" : "false", recovery_events, isolated_peak_kb);
            return 0;
        }
        aeic::Bitstream stream;
        if (!args.best_effort) stream = aeic::read_bitstream(args.bitstream);
        else {
            std::vector<std::string> warnings;
            stream = aeic::read_bitstream_recover(args.bitstream,
                setting_int(codec.settings, "input_height", 256), setting_int(codec.settings, "input_width", 256), warnings);
            for (const auto& warning : warnings) degraded("bitstream", warning);
        }
        std::printf("DECODE_BEGIN height=%u width=%u threads=%d rss_kb=%ld\n", stream.height, stream.width, args.threads, rss_kb()); std::fflush(stdout);
        if (!decode_codec(args, codec, stream, slots)) return 0;
        Manifest renderer = manifest(join(args.directory, "renderer.tsv"));
        if (renderer.stages.empty()) throw std::runtime_error("renderer has no stages");
        std::string output_slot = renderer.settings.count("output_slot") ? renderer.settings.at("output_slot") : "rgb";
        std::string range = renderer.settings.count("rgb_range") ? renderer.settings.at("rgb_range") : "-1,1";
        for (size_t i = 0; i < renderer.stages.size(); ++i) {
            execute(args, renderer.stages[i], slots);
            release_unused(slots, renderer.stages, i + 1, {output_slot});
            if (stop(args, renderer.stages[i].name)) return 0;
        }
        ppm(args.output, slot(slots, output_slot), stream.height, stream.width, range);
        auto output_bytes = aeic::read_file(args.output);
        std::printf("DECODE_COMPLETE height=%u width=%u seconds=%.3f rss_kb=%ld peak_kb=%ld image_fnv1a64=%s output=%s\n",
            stream.height, stream.width, elapsed(started), rss_kb(), peak_kb(),
            aeic::hash_hex(aeic::hash_bytes(output_bytes.data(), output_bytes.size())).c_str(), args.output.c_str());
        std::printf("RESULT_STATUS degraded=%s recovery_events=%zu child_peak_kb=%ld\n",
            recovery_events ? "true" : "false", recovery_events, isolated_peak_kb);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "AEIC_ERROR %s\n", error.what());
        return 1;
    }
}
