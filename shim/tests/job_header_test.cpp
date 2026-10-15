#include <gtest/gtest.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include "raftrkt/job.hpp"

namespace {

template <auto Fn>
using layout_of = raftrkt::detail::job_signature<decltype(Fn)>::layout;

int fit_shaped(void* /*handle*/, const rr_view* /*x*/, const rr_view* /*w*/,
               const rr_view* /*c*/, int32_t /*init*/, int32_t /*max_iter*/,
               double /*tol*/, int32_t /*n_init*/, double /*factor*/,
               uint64_t /*seed*/, double* /*inertia*/, int32_t* /*n_iter*/) {
  return 0;
}

struct fit_block {
  void* handle;
  rr_view x;
  rr_view w;
  rr_view c;
  int32_t init;
  int32_t max_iter;
  double tol;
  int32_t n_init;
  double factor;
  uint64_t seed;
  double inertia;
  int32_t n_iter;
};

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- mirrors the probe C ABI
int echo(int8_t a, int16_t b, int32_t c, int64_t d, uint8_t e, uint16_t f,
         uint32_t g, uint64_t h, float i, double j, int8_t* oa, int16_t* ob,
         int32_t* oc, int64_t* od, uint8_t* oe, uint16_t* of, uint32_t* og,
         uint64_t* oh, float* oi, double* oj) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  *oa = a;
  *ob = b;
  *oc = c;
  *od = d;
  *oe = e;
  *of = f;
  *og = g;
  *oh = h;
  *oi = i;
  *oj = j;
  return 0;
}

struct echo_block {
  int8_t a;
  int16_t b;
  int32_t c;
  int64_t d;
  uint8_t e;
  uint16_t f;
  uint32_t g;
  uint64_t h;
  float i;
  double j;
  int8_t oa;
  int16_t ob;
  int32_t oc;
  int64_t od;
  uint8_t oe;
  uint16_t of;
  uint32_t og;
  uint64_t oh;
  float oi;
  double oj;
};

int calls = 0;

int gate(int32_t /*entered*/, int32_t /*gate*/, int32_t /*timeout*/,
         int32_t /*say*/, int32_t /*fail*/, int32_t* opened) {
  ++calls;
  *opened = 1;
  return 0;
}

struct gate_block {
  int32_t entered;
  int32_t gate;
  int32_t timeout;
  int32_t say;
  int32_t fail;
  int32_t opened;
};

int nothing() {
  return 0;
}

int mixed(int8_t /*a*/, double* /*b*/, int16_t /*c*/, const rr_view* /*v*/,
          float /*d*/) {
  return 0;
}

struct mixed_block {
  int8_t a;
  double b;
  int16_t c;
  rr_view v;
  float d;
};

int bytes_and_words(uint8_t /*a*/, uint64_t /*b*/, uint8_t* /*c*/) {
  return 0;
}

struct bytes_and_words_block {
  uint8_t a;
  uint64_t b;
  uint8_t c;
};

const rr_view* seen_x = nullptr;
const rr_view* seen_y = nullptr;
rr_view seen_y_copy{};

// NOLINTBEGIN(bugprone-easily-swappable-parameters) -- mirrors the probe C ABI
int views(const rr_view* x, const rr_view* y) {
  // NOLINTEND(bugprone-easily-swappable-parameters)
  seen_x = x;
  seen_y = y;
  if (y != nullptr) {
    seen_y_copy = *y;
  }
  return 0;
}

raftrkt::error_slot slot;
int returned_status = 0;

int failing(int32_t status) {
  returned_status = status;
  raftrkt::record_error(slot, "slot message", raftrkt::error_kind::cuda);
  return status;
}

constexpr int thrown_int = 5;
constexpr std::size_t long_message_bytes = 5000;
constexpr unsigned continuation_mask = 0xC0U;
constexpr unsigned continuation_bits = 0x80U;
constexpr int32_t small_negative = -7;
constexpr uint32_t large_unsigned = 4000000000U;
constexpr int64_t large_signed = 1234567890123;
constexpr float some_float = 1.5F;
constexpr double some_double = -2.25;
constexpr double exact_double = 0.125;

int throws_logic(int32_t /*unused*/) {
  throw raftrkt::logic_error("thrown logic");
}

int throws_five(int32_t /*unused*/) {
  throw thrown_int;
}

std::string long_message() {
  std::string text;
  while (text.size() < long_message_bytes) {
    text += "\xC3\xA9";
  }
  return text;
}

int throws_long(int32_t /*unused*/) {
  throw std::runtime_error(long_message());
}

int records_long(int32_t /*unused*/) {
  raftrkt::record_error(slot, long_message().c_str(),
                        raftrkt::error_kind::logic);
  return 1;
}

bool valid_utf8(const char* text) {
  const auto* p = reinterpret_cast<const unsigned char*>(text);
  while (*p != 0) {
    const std::size_t n = raftrkt::detail::utf8_sequence_length(*p);
    for (std::size_t k = 1; k < n; ++k) {
      if ((p[k] & continuation_mask) != continuation_bits) {
        return false;
      }
    }
    p += n;
  }
  return true;
}

template <auto Fn, typename Block>
rr_job_outcome run_on(Block& block) {
  rr_job_outcome outcome{};
  raftrkt::run_job<Fn>(&block, sizeof block, &outcome, slot);
  return outcome;
}

}  // namespace

static_assert(raftrkt::job_parameter<void*>);
static_assert(raftrkt::job_parameter<const rr_view*>);
static_assert(raftrkt::job_parameter<int32_t>);
static_assert(raftrkt::job_parameter<double*>);
static_assert(raftrkt::job_parameter<rr_deposit*>);
static_assert(!raftrkt::job_parameter<const double*>);
static_assert(!raftrkt::job_parameter<rr_view*>);
static_assert(!raftrkt::job_parameter<const void*>);
static_assert(!raftrkt::job_parameter<std::string>);

TEST(JobHeader, ArgsSizeIsTheCStructSize) {
  EXPECT_EQ(raftrkt::job_args_size<&fit_shaped>, 520U);
  EXPECT_EQ(raftrkt::job_args_size<&fit_shaped>, sizeof(fit_block));
  EXPECT_EQ(raftrkt::job_args_size<&echo>, 96U);
  EXPECT_EQ(raftrkt::job_args_size<&gate>, 24U);
  EXPECT_EQ(raftrkt::job_args_size<&nothing>, 0U);
  EXPECT_EQ(raftrkt::job_args_size<&mixed>, sizeof(mixed_block));
  EXPECT_EQ(raftrkt::job_args_size<&bytes_and_words>,
            sizeof(bytes_and_words_block));
}

TEST(JobHeader, OffsetsAreTheCStructOffsets) {
  EXPECT_EQ(layout_of<&fit_shaped>::offsets,
            (std::array<std::size_t, 12>{
                offsetof(fit_block, handle), offsetof(fit_block, x),
                offsetof(fit_block, w), offsetof(fit_block, c),
                offsetof(fit_block, init), offsetof(fit_block, max_iter),
                offsetof(fit_block, tol), offsetof(fit_block, n_init),
                offsetof(fit_block, factor), offsetof(fit_block, seed),
                offsetof(fit_block, inertia), offsetof(fit_block, n_iter)}));
  EXPECT_EQ(layout_of<&echo>::offsets,
            (std::array<std::size_t, 20>{
                offsetof(echo_block, a),  offsetof(echo_block, b),
                offsetof(echo_block, c),  offsetof(echo_block, d),
                offsetof(echo_block, e),  offsetof(echo_block, f),
                offsetof(echo_block, g),  offsetof(echo_block, h),
                offsetof(echo_block, i),  offsetof(echo_block, j),
                offsetof(echo_block, oa), offsetof(echo_block, ob),
                offsetof(echo_block, oc), offsetof(echo_block, od),
                offsetof(echo_block, oe), offsetof(echo_block, of),
                offsetof(echo_block, og), offsetof(echo_block, oh),
                offsetof(echo_block, oi), offsetof(echo_block, oj)}));
  EXPECT_EQ(layout_of<&gate>::offsets,
            (std::array<std::size_t, 6>{
                offsetof(gate_block, entered), offsetof(gate_block, gate),
                offsetof(gate_block, timeout), offsetof(gate_block, say),
                offsetof(gate_block, fail), offsetof(gate_block, opened)}));
  EXPECT_EQ(layout_of<&mixed>::offsets,
            (std::array<std::size_t, 5>{
                offsetof(mixed_block, a), offsetof(mixed_block, b),
                offsetof(mixed_block, c), offsetof(mixed_block, v),
                offsetof(mixed_block, d)}));
  EXPECT_EQ(layout_of<&bytes_and_words>::offsets,
            (std::array<std::size_t, 3>{offsetof(bytes_and_words_block, a),
                                        offsetof(bytes_and_words_block, b),
                                        offsetof(bytes_and_words_block, c)}));
}

TEST(JobHeader, ScalarsRoundTripAndOutputsAreWrittenBack) {
  echo_block block{};
  block.a = INT8_MIN;
  block.b = INT16_MAX;
  block.c = small_negative;
  block.d = INT64_MIN;
  block.e = UINT8_MAX;
  block.f = UINT16_MAX;
  block.g = large_unsigned;
  block.h = UINT64_MAX;
  block.i = some_float;
  block.j = some_double;
  const rr_job_outcome outcome = run_on<&echo>(block);
  EXPECT_EQ(outcome.status, RR_OK);
  EXPECT_EQ(outcome.kind, 0);
  EXPECT_STREQ(outcome.message, "");
  EXPECT_EQ(block.oa, block.a);
  EXPECT_EQ(block.ob, block.b);
  EXPECT_EQ(block.oc, block.c);
  EXPECT_EQ(block.od, block.d);
  EXPECT_EQ(block.oe, block.e);
  EXPECT_EQ(block.of, block.f);
  EXPECT_EQ(block.og, block.g);
  EXPECT_EQ(block.oh, block.h);
  EXPECT_EQ(block.oi, block.i);
  EXPECT_EQ(block.oj, block.j);
}

TEST(JobHeader, AnAbsentViewIsNullAndABoundOneIsACopy) {
  std::array<rr_view, 2> block{};
  block[0].dtype = -1;
  block[1].dtype = RR_DTYPE_FLOAT64;
  block[1].rank = 2;
  block[1].shape[0] = 3;
  block[1].shape[1] = 4;
  const rr_job_outcome outcome = run_on<&views>(block);
  EXPECT_EQ(outcome.status, RR_OK);
  EXPECT_EQ(seen_x, nullptr);
  ASSERT_NE(seen_y, nullptr);
  EXPECT_NE(seen_y, &block[1]);
  EXPECT_EQ(sizeof seen_y_copy, 152U);
  EXPECT_EQ(seen_y_copy.dtype, RR_DTYPE_FLOAT64);
  EXPECT_EQ(seen_y_copy.shape[1], 4);
}

TEST(JobHeader, AMisalignedBlockWorks) {
  std::vector<std::byte> bytes(sizeof(echo_block) + 1);
  echo_block block{};
  block.d = large_signed;
  block.j = exact_double;
  std::memcpy(bytes.data() + 1, &block, sizeof block);
  rr_job_outcome outcome{};
  raftrkt::run_job<&echo>(bytes.data() + 1, sizeof block, &outcome, slot);
  std::memcpy(&block, bytes.data() + 1, sizeof block);
  EXPECT_EQ(outcome.status, RR_OK);
  EXPECT_EQ(block.od, large_signed);
  EXPECT_EQ(block.oj, exact_double);
}

TEST(JobHeader, ASizeMismatchIsRefusedWithoutCalling) {
  calls = 0;
  std::array<int32_t, 2> block{};
  rr_job_outcome outcome{};
  raftrkt::run_job<&gate>(block.data(), sizeof block, &outcome, slot);
  EXPECT_EQ(outcome.status, RR_ERROR);
  EXPECT_EQ(outcome.kind, RR_ERROR_LOGIC);
  EXPECT_STREQ(outcome.message,
               "the argument block is 8 bytes; the job expects 24");
  EXPECT_EQ(calls, 0);
}

TEST(JobHeader, StatusesKindsAndMessages) {
  int32_t block = 1;
  rr_job_outcome outcome = run_on<&failing>(block);
  EXPECT_EQ(outcome.status, RR_ERROR);
  EXPECT_EQ(outcome.kind, RR_ERROR_CUDA);
  EXPECT_STREQ(outcome.message, "slot message");
  block = 2;
  outcome = run_on<&failing>(block);
  EXPECT_EQ(outcome.status, 2);
  outcome = run_on<&throws_logic>(block);
  EXPECT_EQ(outcome.status, RR_ERROR);
  EXPECT_EQ(outcome.kind, RR_ERROR_LOGIC);
  EXPECT_STREQ(outcome.message, "thrown logic");
  outcome = run_on<&throws_five>(block);
  EXPECT_EQ(outcome.status, RR_ERROR);
  EXPECT_EQ(outcome.kind, RR_ERROR_GENERIC);
  EXPECT_STREQ(outcome.message, "unknown exception");
}

TEST(JobHeader, ALongMessageIsTruncatedAtACharacter) {
  int32_t block = 0;
  for (const rr_job_outcome& outcome :
       {run_on<&throws_long>(block), run_on<&records_long>(block)}) {
    EXPECT_EQ(outcome.status, RR_ERROR);
    const std::size_t length = std::strlen(outcome.message);
    EXPECT_LE(length, 4095U);
    EXPECT_GT(length, 4000U);
    EXPECT_TRUE(valid_utf8(outcome.message));
  }
}
