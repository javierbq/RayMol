/*
 * GPU frame times (#616). See GpuFrameTimes.h. Pure C++: no PyMOLGlobals, no
 * Python, no Metal.
 */

#include "GpuFrameTimes.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace pymol
{

GpuFrameSummary GpuFrameSummarize(std::vector<double> samples)
{
  samples.erase(std::remove_if(samples.begin(), samples.end(),
                    [](double v) { return !std::isfinite(v) || v < 0.0; }),
      samples.end());
  GpuFrameSummary s;
  if (samples.empty())
    return s;
  std::sort(samples.begin(), samples.end());
  const std::size_t n = samples.size();
  double sum = 0.0;
  for (double v : samples)
    sum += v;
  s.count = int(n);
  s.mean = sum / double(n);
  s.median = (n % 2) ? samples[n / 2]
                     : 0.5 * (samples[n / 2 - 1] + samples[n / 2]);
  // nearest rank: the smallest value with at least 95% of samples <= it
  std::size_t rank = (95 * n + 99) / 100; // ceil(0.95 n), exact in integers
  rank = std::clamp<std::size_t>(rank, 1, n);
  s.p95 = samples[rank - 1];
  s.max = samples.back();
  return s;
}

void GpuFrameTimes::add(double ms, int shadowMaps, int shadowSize)
{
  if (!std::isfinite(ms) || ms < 0.0)
    return;
  std::lock_guard<std::mutex> lock(m_mutex);
  if (m_ring.size() < kCapacity) {
    m_ring.push_back(ms);
  } else {
    m_ring[m_next] = ms;
  }
  m_next = (m_next + 1) % kCapacity;
  m_lastMs = ms;
  m_shadowMaps = shadowMaps;
  m_shadowSize = shadowSize;
}

bool GpuFrameTimes::report(GpuFrameReport& out, int mode) const
{
  std::vector<double> copy;
  {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (m_ring.empty())
      return false;
    copy = m_ring;
    out.lastMs = m_lastMs;
    out.shadowMaps = m_shadowMaps;
    out.shadowSize = m_shadowSize;
  }
  out.mode = mode;
  out.summary = GpuFrameSummarize(std::move(copy));
  return true;
}

void GpuFrameTimes::clear()
{
  std::lock_guard<std::mutex> lock(m_mutex);
  m_ring.clear();
  m_next = 0;
  m_lastMs = 0.0;
  m_shadowMaps = 0;
  m_shadowSize = 0;
}

} // namespace pymol
