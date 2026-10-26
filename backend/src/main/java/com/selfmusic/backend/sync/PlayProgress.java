package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.selfmusic.backend.domain.entity.SongState;

import java.util.ArrayList;
import java.util.List;

/**
 * 播放进度直方图（101 桶，0..100%）与升权中位闸门。
 *
 * 服务端直方图只由样本事件累加：complete/skip 带 progress_pct、song.progress
 * 普通样本各 +1 桶；baseline 基线按桶 max。客户端快照合并也按桶 max，
 * 因此同一事件重复到达不会重复计数。
 */
public final class PlayProgress {
    public static final int BUCKET_COUNT = 101;
    public static final int MIN_SAMPLES = 3;
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private PlayProgress() {}

    public static boolean hasSample(JsonNode payload) {
        return payload != null
                && payload.has("progress_pct")
                && !payload.get("progress_pct").isNull();
    }

    /** 把载荷里的 progress_pct 记入直方图；不是样本事件则无动作。 */
    public static void recordSample(SongState song, JsonNode payload) {
        if (!hasSample(payload)) return;
        int pct = clamp(payload.path("progress_pct").asInt(0));
        song.setProgressHist(record(song.getProgressHist(), pct));
    }

    public static String record(String histJson, int percent) {
        int[] counts = parse(histJson);
        counts[clamp(percent)]++;
        return encode(counts);
    }

    /** 基线合并：按桶取 max，不累加。 */
    public static String mergeMax(String histJson, JsonNode incoming) {
        int[] current = parse(histJson);
        int[] add = parseNode(incoming);
        for (int i = 0; i < BUCKET_COUNT; i++) {
            if (add[i] > current[i]) current[i] = add[i];
        }
        return encode(current);
    }

    public static int total(String histJson) {
        int sum = 0;
        for (int c : parse(histJson)) sum += c;
        return sum;
    }

    /** 中位数（偶数取中间两桶均值）；无样本返回 -1。 */
    public static double median(String histJson) {
        int[] counts = parse(histJson);
        long n = 0;
        for (int c : counts) n += c;
        if (n == 0) return -1;
        long lowerRank = (n - 1) / 2;
        long upperRank = n / 2;
        int lower = -1;
        int upper = -1;
        long cumulative = 0;
        for (int i = 0; i < BUCKET_COUNT; i++) {
            cumulative += counts[i];
            if (lower < 0 && cumulative > lowerRank) lower = i;
            if (upper < 0 && cumulative > upperRank) {
                upper = i;
                break;
            }
        }
        if (lower < 0 || upper < 0) return -1;
        return (lower + upper) / 2.0;
    }

    /** 目标权重的升权中位门槛；目标 <= 1.0 返回 -1（不设闸门）。 */
    public static double requiredMedian(double targetFactor) {
        if (targetFactor <= 1.0 + 1e-9) return -1;
        double v = 50.0 + (targetFactor - 1.1) * 50.0;
        v = Math.max(0.0, Math.min(100.0, v));
        return Math.round(v * 100.0) / 100.0;
    }

    public static boolean allowsUpgrade(String histJson, double targetFactor) {
        double required = requiredMedian(targetFactor);
        if (required < 0) return true;
        if (total(histJson) < MIN_SAMPLES) return false;
        return median(histJson) + 1e-9 >= required;
    }

    public static int[] parse(String histJson) {
        if (histJson == null || histJson.isBlank()) return new int[BUCKET_COUNT];
        try {
            return parseNode(MAPPER.readTree(histJson));
        } catch (Exception e) {
            return new int[BUCKET_COUNT];
        }
    }

    private static int[] parseNode(JsonNode node) {
        int[] counts = new int[BUCKET_COUNT];
        if (node == null || !node.isArray()) return counts;
        int n = Math.min(node.size(), BUCKET_COUNT);
        for (int i = 0; i < n; i++) {
            counts[i] = Math.max(0, node.get(i).asInt(0));
        }
        return counts;
    }

    public static String encode(int[] counts) {
        if (counts == null) return null;
        ArrayNode arr = MAPPER.createArrayNode();
        int total = 0;
        for (int i = 0; i < BUCKET_COUNT; i++) {
            int c = counts[i] > 0 ? counts[i] : 0;
            arr.add(c);
            total += c;
        }
        if (total == 0) return null;
        try {
            return MAPPER.writeValueAsString(arr);
        } catch (Exception e) {
            return null;
        }
    }

    public static List<Integer> toList(String histJson) {
        List<Integer> out = new ArrayList<>(BUCKET_COUNT);
        for (int c : parse(histJson)) out.add(c);
        return out;
    }

    private static int clamp(int percent) {
        return Math.max(0, Math.min(100, percent));
    }
}
