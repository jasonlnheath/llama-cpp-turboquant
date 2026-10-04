// Regression test for the async-CPU job drain on split errors.
//
// ggml_backend_sched_compute_splits launches the last-backend (CPU) split on
// the async worker thread and keeps iterating later splits. When a later
// (GPU) split's compute fails, the function must JOIN the in-flight CPU job
// before returning the error - otherwise the next eval rewrites the split
// graph and frees tensor metadata while the worker still computes the stale
// split (use-after-free).
//
// The test builds two mock backends: a GPU-like backend whose graph_compute
// fails immediately, and a CPU-like backend whose graph_compute sleeps 300 ms
// before setting a completion flag. With the drain in place, the error return
// happens only after the CPU job completed (flag set, elapsed >= sleep);
// without the drain the error returns in microseconds with the flag unset.

#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-cpp.h"
#include "../ggml/src/ggml-backend-impl.h"
#include "../ggml/src/ggml-impl.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <thread>

using steady_clock = std::chrono::steady_clock;

struct mock_state {
    const char *               name;
    enum ggml_backend_dev_type dev_type;
    int          compute_delay_ms; // sleep inside graph_compute
    enum ggml_status compute_status; // returned by graph_compute
    std::atomic<int>    computes{0};
    std::atomic<bool> * done_flag; // set after the delay (CPU mock)

    ggml_backend_buffer_type_t self_buft; // filled during assembly
};

struct mock_buffer_ctx {
    std::unique_ptr<char[]> block;
};

// ---- buffer type iface ----

static struct ggml_backend_buffer_i mock_buffer_iface();

static const char * mock_buft_get_name(ggml_backend_buffer_type_t buft) {
    return ((mock_state *) buft->context)->name;
}

static ggml_backend_buffer_t mock_buft_alloc_buffer(ggml_backend_buffer_type_t buft, size_t size) {
    auto * mbc = new mock_buffer_ctx;
    mbc->block = std::make_unique<char[]>(size ? size : 1);
    std::memset(mbc->block.get(), 0, size);
    return ggml_backend_buffer_init(buft, mock_buffer_iface(), mbc, size);
}

static size_t mock_buft_get_alignment(ggml_backend_buffer_type_t) {
    return 32;
}

static bool mock_buft_is_host(ggml_backend_buffer_type_t buft) {
    return ((mock_state *) buft->context)->dev_type == GGML_BACKEND_DEVICE_TYPE_CPU;
}

// ---- buffer iface (malloc-backed, real memory so tensor copies work) ----

static void mock_buffer_free_buffer(ggml_backend_buffer_t buffer) {
    delete (mock_buffer_ctx *) buffer->context;
}

static void * mock_buffer_get_base(ggml_backend_buffer_t buffer) {
    return ((mock_buffer_ctx *) buffer->context)->block.get();
}

static ggml_status mock_buffer_init_tensor(ggml_backend_buffer_t, struct ggml_tensor *) {
    return GGML_STATUS_SUCCESS;
}

static void mock_buffer_memset_tensor(ggml_backend_buffer_t, struct ggml_tensor * t, uint8_t value, size_t offset, size_t size) {
    std::memset((char *) t->data + offset, value, size);
}

static void mock_buffer_set_tensor(ggml_backend_buffer_t, struct ggml_tensor * t, const void * data, size_t offset, size_t size) {
    std::memcpy((char *) t->data + offset, data, size);
}

static void mock_buffer_get_tensor(ggml_backend_buffer_t, const struct ggml_tensor * t, void * data, size_t offset, size_t size) {
    std::memcpy(data, (const char *) t->data + offset, size);
}

static void mock_buffer_clear(ggml_backend_buffer_t, uint8_t) {}

static struct ggml_backend_buffer_i mock_buffer_iface() {
    struct ggml_backend_buffer_i iface = {};
    iface.free_buffer   = mock_buffer_free_buffer;
    iface.get_base      = mock_buffer_get_base;
    iface.init_tensor   = mock_buffer_init_tensor;
    iface.memset_tensor = mock_buffer_memset_tensor;
    iface.set_tensor    = mock_buffer_set_tensor;
    iface.get_tensor    = mock_buffer_get_tensor;
    iface.clear         = mock_buffer_clear;
    return iface;
}

// ---- device iface ----

static const char * mock_dev_get_name(ggml_backend_dev_t dev) {
    return ((mock_state *) dev->context)->name;
}

static void mock_dev_get_memory(ggml_backend_dev_t, size_t * free, size_t * total) {
    *free  = 1ull << 30;
    *total = 1ull << 30;
}

static enum ggml_backend_dev_type mock_dev_get_type(ggml_backend_dev_t dev) {
    return ((mock_state *) dev->context)->dev_type;
}

static void mock_dev_get_props(ggml_backend_dev_t dev, struct ggml_backend_dev_props * props) {
    props->name        = mock_dev_get_name(dev);
    props->description = mock_dev_get_name(dev);
    props->device_id   = nullptr;
    mock_dev_get_memory(dev, &props->memory_free, &props->memory_total);
    props->type        = mock_dev_get_type(dev);
    props->caps.async                = false;
    props->caps.host_buffer          = false;
    props->caps.buffer_from_host_ptr = false;
    props->caps.events               = false;
}

static ggml_backend_buffer_type_t mock_dev_get_buffer_type(ggml_backend_dev_t dev) {
    return ((mock_state *) dev->context)->self_buft;
}

static bool mock_dev_supports_op(ggml_backend_dev_t, const struct ggml_tensor *) {
    return true;
}

static bool mock_dev_supports_buft(ggml_backend_dev_t, ggml_backend_buffer_type_t) {
    return true;
}

// ---- backend iface ----

static const char * mock_backend_get_name(ggml_backend_t backend) {
    return ((mock_state *) backend->context)->name;
}

static void mock_backend_free(ggml_backend_t) {}

static enum ggml_status mock_backend_graph_compute(ggml_backend_t backend, struct ggml_cgraph *) {
    mock_state * m = (mock_state *) backend->context;
    m->computes++;
    if (m->compute_delay_ms > 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(m->compute_delay_ms));
    }
    if (m->done_flag) {
        m->done_flag->store(true);
    }
    return m->compute_status;
}

// ---- mock assembly ----

struct mock {
    mock_state                  state;
    ggml_backend_buffer_type_t  buft;
    ggml_backend_dev_t          dev;
    ggml_backend_t              backend;

    // the scheduler does not free caller-owned backends
    ~mock() {
        delete backend;
        delete dev;
        delete buft;
    }
};

static std::unique_ptr<mock> make_mock(const char * name, enum ggml_backend_dev_type type,
                                       int delay_ms, enum ggml_status status, std::atomic<bool> * done_flag) {
    auto m = std::make_unique<mock>();
    m->state.name             = name;
    m->state.dev_type         = type;
    m->state.compute_delay_ms = delay_ms;
    m->state.compute_status   = status;
    m->state.done_flag        = done_flag;

    auto * buft = new ggml_backend_buffer_type();
    std::memset(buft, 0, sizeof(*buft));
    buft->context             = &m->state;
    buft->iface.get_name      = mock_buft_get_name;
    buft->iface.alloc_buffer  = mock_buft_alloc_buffer;
    buft->iface.get_alignment = mock_buft_get_alignment;
    buft->iface.is_host       = mock_buft_is_host;
    m->state.self_buft = buft;
    m->buft = buft;

    auto * dev = new ggml_backend_device();
    std::memset(dev, 0, sizeof(*dev));
    dev->context               = &m->state;
    dev->iface.get_name        = mock_dev_get_name;
    dev->iface.get_description = mock_dev_get_name;
    dev->iface.get_memory      = mock_dev_get_memory;
    dev->iface.get_type        = mock_dev_get_type;
    dev->iface.get_props       = mock_dev_get_props;
    dev->iface.get_buffer_type = mock_dev_get_buffer_type;
    dev->iface.supports_op     = mock_dev_supports_op;
    dev->iface.supports_buft   = mock_dev_supports_buft;
    m->dev = dev;

    auto * backend = new ggml_backend();
    std::memset(backend, 0, sizeof(*backend));
    backend->device              = dev;
    backend->context             = &m->state;
    backend->iface.get_name      = mock_backend_get_name;
    backend->iface.free          = mock_backend_free;
    backend->iface.graph_compute = mock_backend_graph_compute;
    m->backend = backend;

    return m;
}

int main() {
    std::atomic<bool> cpu_done{false};

    // GPU-like backend: fails immediately. CPU-like backend (must be last for
    // the async-launch branch): sleeps 300 ms, then flags completion.
    auto gpu = make_mock("MOCK-GPU", GGML_BACKEND_DEVICE_TYPE_GPU, 0, GGML_STATUS_FAILED, nullptr);
    auto cpu = make_mock("MOCK-CPU", GGML_BACKEND_DEVICE_TYPE_CPU, 300, GGML_STATUS_SUCCESS, &cpu_done);

    ggml_backend_t             backends[2] = { gpu->backend, cpu->backend };
    ggml_backend_buffer_type_t bufts[2]    = { gpu->buft, cpu->buft };

    ggml_backend_sched_t sched = ggml_backend_sched_new(backends, bufts, 2, 128, false, false);
    GGML_ASSERT(sched);
    ggml_backend_sched_set_async_cpu(sched, true);

    // graph: s1 = x + y on the CPU backend; s2 = w * w on the GPU backend.
    // s2 must not depend on s1: a cross-backend input would make the pending
    // CPU job join before the GPU failure (the must_join check in
    // compute_splits) and mask the error-path drain this test guards
    ggml_init_params ip{};
    ip.mem_size = 16 * ggml_tensor_overhead() + ggml_graph_overhead();
    ip.no_alloc = true;
    ggml_context_ptr ctx(ggml_init(ip));

    ggml_tensor * x = ggml_new_tensor_1d(ctx.get(), GGML_TYPE_F32, 16);
    ggml_tensor * y = ggml_new_tensor_1d(ctx.get(), GGML_TYPE_F32, 16);
    ggml_tensor * w = ggml_new_tensor_1d(ctx.get(), GGML_TYPE_F32, 16);
    ggml_set_input(x);
    ggml_set_input(y);
    ggml_set_input(w);

    ggml_tensor * s1 = ggml_add(ctx.get(), x, y);
    ggml_tensor * s2 = ggml_mul(ctx.get(), w, w);
    ggml_set_output(s1);
    ggml_set_output(s2);

    ggml_cgraph * graph = ggml_new_graph(ctx.get());
    ggml_build_forward_expand(graph, s1);
    ggml_build_forward_expand(graph, s2);

    // size the gallocr first; reserve ends with a reset that would drop the
    // manual assignments, so they are made afterwards and the graph is
    // allocated explicitly (a plain graph_compute would reset again)
    if (!ggml_backend_sched_reserve(sched, graph)) {
        printf("FAIL test-sched-async-drain (reserve failed)\n");
        return 1;
    }

    ggml_backend_sched_set_tensor_backend(sched, x, cpu->backend);
    ggml_backend_sched_set_tensor_backend(sched, y, cpu->backend);
    ggml_backend_sched_set_tensor_backend(sched, s1, cpu->backend);
    ggml_backend_sched_set_tensor_backend(sched, w, gpu->backend);
    ggml_backend_sched_set_tensor_backend(sched, s2, gpu->backend);

    if (!ggml_backend_sched_alloc_graph(sched, graph)) {
        printf("FAIL test-sched-async-drain (alloc failed)\n");
        return 1;
    }

    // measure at the compute_splits boundary: the async entry point returns
    // straight from compute_splits (the sync wrapper would join via
    // ggml_backend_sched_synchronize and mask the difference)
    auto           t0 = steady_clock::now();
    enum ggml_status st = ggml_backend_sched_graph_compute_async(sched, graph);
    auto           t1 = steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    bool completed_before_drain = cpu_done.load();

    // drain whatever is left before tearing down
    ggml_backend_sched_synchronize(sched);
    ggml_backend_sched_free(sched);

    printf("status            = %d (expected non-success: %d)\n", (int) st, (int) GGML_STATUS_FAILED);
    printf("cpu computes      = %d (expected >= 1)\n", cpu->state.computes.load());
    printf("gpu computes      = %d (expected >= 1)\n", gpu->state.computes.load());
    printf("cpu job completed = %d (expected 1 - drained before error return)\n", (int) completed_before_drain);
    printf("elapsed ms        = %.1f (expected >= 280 - error return waited for the job)\n", ms);

    bool ok = st != GGML_STATUS_SUCCESS
        && cpu->state.computes.load() >= 1
        && gpu->state.computes.load() >= 1
        && completed_before_drain
        && ms >= 280.0;

    printf("%s\n", ok ? "PASS test-sched-async-drain" : "FAIL test-sched-async-drain");
    return ok ? 0 : 1;
}
