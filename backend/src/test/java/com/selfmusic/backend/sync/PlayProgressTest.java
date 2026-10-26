package com.selfmusic.backend.sync;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.selfmusic.backend.domain.entity.SongState;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class PlayProgressTest {

    private final ObjectMapper mapper = new ObjectMapper();

    private static String hist(int... samples) {
        String h = null;
        for (int s : samples) h = PlayProgress.record(h, s);
        return h;
    }

    @Test
    void emptyHistogramHasNoMedian() {
        assertEquals(0, PlayProgress.total(null));
        assertEquals(-1, PlayProgress.median(null));
        assertNull(PlayProgress.encode(new int[PlayProgress.BUCKET_COUNT]));
        assertEquals(PlayProgress.BUCKET_COUNT, PlayProgress.toList(null).size());
    }

    @Test
    void medianOddAndEven() {
        assertEquals(100, PlayProgress.median(hist(40, 100, 100)), 1e-9);
        assertEquals(70, PlayProgress.median(hist(40, 40, 100, 100)), 1e-9);
    }

    @Test
    void recordClampsPercent() {
        SongState s = new SongState();
        ObjectNode p = mapper.createObjectNode();
        p.put("progress_pct", 120);
        PlayProgress.recordSample(s, p);
        p.put("progress_pct", -5);
        PlayProgress.recordSample(s, p);
        int[] counts = PlayProgress.parse(s.getProgressHist());
        assertEquals(1, counts[100]);
        assertEquals(1, counts[0]);
        assertEquals(2, PlayProgress.total(s.getProgressHist()));
    }

    @Test
    void mergeMaxDoesNotAddCounts() {
        String current = hist(40, 40, 100);
        JsonNode incoming = mapper.valueToTree(PlayProgress.toList(hist(40, 100)));
        String merged = PlayProgress.mergeMax(current, incoming);
        int[] counts = PlayProgress.parse(merged);
        assertEquals(2, counts[40]);
        assertEquals(1, counts[100]);
        assertEquals(3, PlayProgress.total(merged));
    }

    @Test
    void thresholdCurveAndNoGateAtOrBelowOne() {
        assertEquals(-1, PlayProgress.requiredMedian(1.0), 1e-9);
        assertEquals(47.5, PlayProgress.requiredMedian(1.05), 1e-9);
        assertEquals(50, PlayProgress.requiredMedian(1.1), 1e-9);
        assertEquals(55, PlayProgress.requiredMedian(1.2), 1e-9);
        assertEquals(70, PlayProgress.requiredMedian(1.5), 1e-9);
    }

    @Test
    void allowsUpgradeRules() {
        assertTrue(PlayProgress.allowsUpgrade(null, 1.0));
        assertFalse(PlayProgress.allowsUpgrade(null, 1.1));
        assertFalse(PlayProgress.allowsUpgrade(hist(100, 100), 1.1));
        assertFalse(PlayProgress.allowsUpgrade(hist(49, 49, 100), 1.1));
        assertTrue(PlayProgress.allowsUpgrade(hist(50, 50, 100), 1.1));
        assertFalse(PlayProgress.allowsUpgrade(hist(54, 54, 100), 1.2));
        assertTrue(PlayProgress.allowsUpgrade(hist(55, 55, 100), 1.2));
    }

    @Test
    void toListKeeps101Buckets() {
        List<Integer> list = PlayProgress.toList(hist(100));
        assertEquals(PlayProgress.BUCKET_COUNT, list.size());
        assertEquals(1, list.get(100));
    }
}
