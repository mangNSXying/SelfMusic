package com.selfmusic.backend.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(BizException.class)
    public ResponseEntity<ApiResponse<Void>> handleBiz(BizException e) {
        log.warn("BizException [{}]: {}", e.code, e.getMessage());
        return ResponseEntity.badRequest()
                .body(ApiResponse.error(e.code, e.getMessage()));
    }

    /**
     * 保留显式状态码（转码代理的 429 并发满 / 502 源不可达·鉴权失败 / 503 无 ffmpeg），
     * 不落入下方 Exception 兜底被改写成 500。
     */
    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<ApiResponse<Void>> handleStatus(ResponseStatusException e) {
        int status = e.getStatusCode().value();
        String msg = e.getReason() != null ? e.getReason() : e.getMessage();
        log.warn("ResponseStatusException [{}]: {}", status, msg);
        return ResponseEntity.status(e.getStatusCode())
                .body(ApiResponse.error(status, msg));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiResponse<Void>> handleGeneral(Exception e) {
        // 打印完整堆栈，否则线上只剩一个 code=50000 无法排障
        log.error("Unhandled exception", e);
        return ResponseEntity.internalServerError()
                .body(ApiResponse.error(50000, "Internal server error"));
    }
}
