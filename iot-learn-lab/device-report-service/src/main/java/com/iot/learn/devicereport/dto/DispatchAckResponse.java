package com.iot.learn.devicereport.dto;

import com.fasterxml.jackson.annotation.JsonAlias;

public record DispatchAckResponse(
        String ackId,
        String deviceId,
        /** 本服务用 source；下游 dispatch 返回字段名为 result，反序列化时兼容 */
        @JsonAlias("result") String source,
        boolean success) {
}
