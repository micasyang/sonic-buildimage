#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <hiredis/hiredis.h>
#include <syslog.h>
#include <string.h>  // 用于 strcmp

int main() {
    srand(time(NULL));  // 初始化随机种子

    redisContext *c = redisConnect("127.0.0.1", 6379);
    if (c == NULL || c->err) {
        if (c) {
            syslog(LOG_ERR, "Redis connection error: %s", c->errstr);
            redisFree(c);
        } else {
            syslog(LOG_ERR, "Redis connection error: can't allocate redis context");
        }
        return 1;
    }

    openlog("sonic-bmc", LOG_PID, LOG_USER);
    while (1) {
        double flow_rate = (double)rand() / RAND_MAX * 100.0;  // 生成 0.0 到 100.0 的随机流速
        time_t now = time(NULL);  // 获取当前 Unix 时间戳
        syslog(LOG_INFO, "Simulated liquid cooling flow rate at %ld: %.2f", now, flow_rate);

        // 格式化数据字符串： "timestamp:flow_rate"
        char data[64];
        snprintf(data, sizeof(data), "%ld:%.2f", now, flow_rate);

        // 按时间存储到 List（RPUSH 添加到末尾）
        redisReply *reply = redisCommand(c, "RPUSH liquid_flow_rates %s", data);
        if (reply == NULL) {
            syslog(LOG_ERR, "Redis RPUSH error: %s", c->errstr);
        } else if (reply->type == REDIS_REPLY_INTEGER && reply->integer > 0) {
            syslog(LOG_INFO, "Redis write successful: added %s to liquid_flow_rates", data);
        } else {
            syslog(LOG_ERR, "Redis write failed: unexpected reply type %d", reply->type);
        }
        freeReplyObject(reply);  // 释放 reply

        sleep(3);
    }

    redisFree(c);
    closelog();
    return 0;
}