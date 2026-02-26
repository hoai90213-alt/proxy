#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define LP_MAX_HOST 255
#define LP_MAX_TOKEN 255
#define LP_HTTP_BUF 16384
#define LP_MSG_BUF 256
#define LP_UDP_BUF 65535

typedef struct {
    char device_id[128];
    char control_bind_host[LP_MAX_HOST + 1];
    uint16_t control_port;
    char control_auth_token[LP_MAX_TOKEN + 1];
    uint16_t local_proxy_port;
    char remote_default_host[LP_MAX_HOST + 1];
    uint16_t remote_default_port;
} lp_config_t;

typedef enum {
    LP_STOPPED = 0,
    LP_STARTING = 1,
    LP_RUNNING = 2,
    LP_STOPPING = 3
} lp_state_t;

typedef struct lp_relay_s lp_relay_t;

typedef struct {
    pthread_mutex_t lock;
    lp_state_t state;
    char target_host[LP_MAX_HOST + 1];
    uint16_t target_port;
    char message[LP_MSG_BUF];
    time_t updated_at;
    lp_relay_t *relay;
} lp_runtime_t;

typedef struct {
    lp_config_t cfg;
    lp_runtime_t rt;
} lp_app_t;

struct lp_relay_s {
    lp_app_t *app;
    pthread_t thread;
    volatile int stop_flag;
    int wake_pipe[2];
    int local_fd;
    int remote_fd;
    uint16_t local_port;
    char remote_host[LP_MAX_HOST + 1];
    uint16_t remote_port;
    struct sockaddr_storage client_addr;
    socklen_t client_addr_len;
    int has_client;
};

typedef struct {
    char method[8];
    char path[128];
    char auth[512];
    const char *body;
    size_t body_len;
} lp_http_req_t;

static void lp_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stdout, "[luminaproxyd] ");
    vfprintf(stdout, fmt, ap);
    fprintf(stdout, "\n");
    fflush(stdout);
    va_end(ap);
}

static void lp_touch_locked(lp_runtime_t *rt) {
    rt->updated_at = time(NULL);
}

static void lp_set_message_locked(lp_runtime_t *rt, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(rt->message, sizeof(rt->message), fmt, ap);
    va_end(ap);
    lp_touch_locked(rt);
}

static void lp_set_state_locked(lp_runtime_t *rt, lp_state_t st) {
    rt->state = st;
    lp_touch_locked(rt);
}

static const char *lp_state_name(lp_state_t st) {
    switch (st) {
        case LP_STOPPED: return "stopped";
        case LP_STARTING: return "starting";
        case LP_RUNNING: return "running";
        case LP_STOPPING: return "stopping";
        default: return "unknown";
    }
}

static const char *lp_skip_ws(const char *p) {
    while (p && *p && isspace((unsigned char)*p)) p++;
    return p;
}

static const char *lp_find_json_key(const char *json, const char *key) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = json;
    while ((p = strstr(p, needle)) != NULL) {
        p += strlen(needle);
        p = lp_skip_ws(p);
        if (*p != ':') continue;
        return lp_skip_ws(p + 1);
    }
    return NULL;
}

static int lp_json_get_string(const char *json, const char *key, char *out, size_t out_sz) {
    const char *p = lp_find_json_key(json, key);
    size_t i = 0;
    if (!p || *p != '"' || out_sz == 0) return 0;
    p++;
    while (*p && *p != '"' && i + 1 < out_sz) {
        if (*p == '\\' && p[1] != '\0') p++;
        out[i++] = *p++;
    }
    if (*p != '"') return 0;
    out[i] = '\0';
    return 1;
}

static int lp_json_get_int(const char *json, const char *key, long *out) {
    const char *p = lp_find_json_key(json, key);
    char *end = NULL;
    long v;
    if (!p) return 0;
    errno = 0;
    v = strtol(p, &end, 10);
    if (errno || end == p) return 0;
    *out = v;
    return 1;
}

static int lp_read_file(const char *path, char **out) {
    FILE *f = fopen(path, "rb");
    long sz;
    char *buf;
    if (!f) return -1;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return -1; }
    sz = ftell(f);
    if (sz < 0) { fclose(f); return -1; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return -1; }
    buf = (char *)calloc((size_t)sz + 1, 1);
    if (!buf) { fclose(f); return -1; }
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) { free(buf); fclose(f); return -1; }
    fclose(f);
    *out = buf;
    return 0;
}

static void lp_config_defaults(lp_config_t *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    strcpy(cfg->device_id, "replace-with-your-device-id");
    strcpy(cfg->control_bind_host, "127.0.0.1");
    cfg->control_port = 8787;
    strcpy(cfg->control_auth_token, "change-me");
    cfg->local_proxy_port = 19132;
    cfg->remote_default_port = 19132;
}

static int lp_config_load(const char *path, lp_config_t *cfg) {
    char *json = NULL;
    long v;
    if (lp_read_file(path, &json) != 0) return -1;
    lp_config_defaults(cfg);
    lp_json_get_string(json, "deviceId", cfg->device_id, sizeof(cfg->device_id));
    lp_json_get_string(json, "controlBindHost", cfg->control_bind_host, sizeof(cfg->control_bind_host));
    lp_json_get_string(json, "controlAuthToken", cfg->control_auth_token, sizeof(cfg->control_auth_token));
    lp_json_get_string(json, "remoteDefaultHost", cfg->remote_default_host, sizeof(cfg->remote_default_host));
    if (lp_json_get_int(json, "controlPort", &v) && v > 0 && v <= 65535) cfg->control_port = (uint16_t)v;
    if (lp_json_get_int(json, "localProxyPort", &v) && v > 0 && v <= 65535) cfg->local_proxy_port = (uint16_t)v;
    if (lp_json_get_int(json, "remoteDefaultPort", &v) && v > 0 && v <= 65535) cfg->remote_default_port = (uint16_t)v;
    free(json);
    return 0;
}

static void lp_runtime_init(lp_runtime_t *rt, const lp_config_t *cfg) {
    memset(rt, 0, sizeof(*rt));
    pthread_mutex_init(&rt->lock, NULL);
    rt->state = LP_STOPPED;
    rt->updated_at = time(NULL);
    if (cfg->remote_default_host[0]) {
        strncpy(rt->target_host, cfg->remote_default_host, sizeof(rt->target_host) - 1);
        rt->target_port = cfg->remote_default_port;
    }
    strcpy(rt->message, "Idle");
}

static void lp_runtime_destroy(lp_runtime_t *rt) {
    pthread_mutex_destroy(&rt->lock);
}

static void lp_closefd(int *fd) {
    if (*fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

static void lp_runtime_event(lp_app_t *app, const char *fmt, ...) {
    va_list ap;
    pthread_mutex_lock(&app->rt.lock);
    va_start(ap, fmt);
    vsnprintf(app->rt.message, sizeof(app->rt.message), fmt, ap);
    va_end(ap);
    lp_touch_locked(&app->rt);
    pthread_mutex_unlock(&app->rt.lock);
}

static int lp_udp_bind_loopback(uint16_t port) {
    int fd = -1;
    int one = 1;
    struct sockaddr_in addr;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int lp_udp_connect_remote(const char *host, uint16_t port) {
    struct addrinfo hints, *res = NULL, *it;
    char port_str[16];
    int fd = -1;
    snprintf(port_str, sizeof(port_str), "%u", (unsigned)port);
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_family = AF_UNSPEC;
    if (getaddrinfo(host, port_str, &hints, &res) != 0) return -1;
    for (it = res; it; it = it->ai_next) {
        fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, it->ai_addr, it->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static void lp_drain_pipe(int fd) {
    char buf[64];
    while (read(fd, buf, sizeof(buf)) > 0) {}
}

static void *lp_relay_thread(void *arg) {
    lp_relay_t *r = (lp_relay_t *)arg;
    unsigned char buf[LP_UDP_BUF];

    r->local_fd = lp_udp_bind_loopback(r->local_port);
    if (r->local_fd < 0) {
        lp_runtime_event(r->app, "Relay failed: bind 127.0.0.1:%u", (unsigned)r->local_port);
        goto fail;
    }
    r->remote_fd = lp_udp_connect_remote(r->remote_host, r->remote_port);
    if (r->remote_fd < 0) {
        lp_runtime_event(r->app, "Relay failed: connect %s:%u", r->remote_host, (unsigned)r->remote_port);
        goto fail;
    }

    lp_runtime_event(r->app, "Relay ready on 127.0.0.1:%u -> %s:%u",
                     (unsigned)r->local_port, r->remote_host, (unsigned)r->remote_port);

    while (!r->stop_flag) {
        fd_set rfds;
        int maxfd = -1;
        FD_ZERO(&rfds);
        FD_SET(r->wake_pipe[0], &rfds);
        if (r->wake_pipe[0] > maxfd) maxfd = r->wake_pipe[0];
        FD_SET(r->local_fd, &rfds);
        if (r->local_fd > maxfd) maxfd = r->local_fd;
        FD_SET(r->remote_fd, &rfds);
        if (r->remote_fd > maxfd) maxfd = r->remote_fd;

        if (select(maxfd + 1, &rfds, NULL, NULL, NULL) < 0) {
            if (errno == EINTR) continue;
            lp_runtime_event(r->app, "Relay select error: %s", strerror(errno));
            goto fail;
        }

        if (FD_ISSET(r->wake_pipe[0], &rfds)) {
            lp_drain_pipe(r->wake_pipe[0]);
            if (r->stop_flag) break;
        }

        if (FD_ISSET(r->local_fd, &rfds)) {
            struct sockaddr_storage src;
            socklen_t src_len = sizeof(src);
            ssize_t n = recvfrom(r->local_fd, buf, sizeof(buf), 0, (struct sockaddr *)&src, &src_len);
            if (n > 0) {
                r->client_addr = src;
                r->client_addr_len = src_len;
                r->has_client = 1;
                (void)send(r->remote_fd, buf, (size_t)n, 0);
            }
        }

        if (FD_ISSET(r->remote_fd, &rfds)) {
            ssize_t n = recv(r->remote_fd, buf, sizeof(buf), 0);
            if (n > 0 && r->has_client) {
                (void)sendto(r->local_fd, buf, (size_t)n, 0,
                             (struct sockaddr *)&r->client_addr, r->client_addr_len);
            }
        }
    }

    pthread_mutex_lock(&r->app->rt.lock);
    if (r->app->rt.relay == r) {
        r->app->rt.relay = NULL;
        lp_set_state_locked(&r->app->rt, LP_STOPPED);
        lp_set_message_locked(&r->app->rt, "Proxy stopped");
    }
    pthread_mutex_unlock(&r->app->rt.lock);
    return NULL;

fail:
    pthread_mutex_lock(&r->app->rt.lock);
    if (r->app->rt.relay == r) {
        r->app->rt.relay = NULL;
        lp_set_state_locked(&r->app->rt, LP_STOPPED);
    }
    pthread_mutex_unlock(&r->app->rt.lock);
    return NULL;
}

static void lp_relay_destroy(lp_relay_t *r) {
    if (!r) return;
    lp_closefd(&r->local_fd);
    lp_closefd(&r->remote_fd);
    lp_closefd(&r->wake_pipe[0]);
    lp_closefd(&r->wake_pipe[1]);
    free(r);
}

static int lp_relay_start(lp_app_t *app, const char *host, uint16_t port) {
    lp_relay_t *r = (lp_relay_t *)calloc(1, sizeof(*r));
    if (!r) return -1;
    r->app = app;
    r->local_fd = -1;
    r->remote_fd = -1;
    r->wake_pipe[0] = -1;
    r->wake_pipe[1] = -1;
    r->local_port = app->cfg.local_proxy_port;
    r->remote_port = port;
    strncpy(r->remote_host, host, sizeof(r->remote_host) - 1);
    if (pipe(r->wake_pipe) != 0) {
        lp_relay_destroy(r);
        return -1;
    }

    pthread_mutex_lock(&app->rt.lock);
    app->rt.relay = r;
    strncpy(app->rt.target_host, host, sizeof(app->rt.target_host) - 1);
    app->rt.target_port = port;
    lp_set_state_locked(&app->rt, LP_STARTING);
    lp_set_message_locked(&app->rt, "Proxy starting...");
    pthread_mutex_unlock(&app->rt.lock);

    if (pthread_create(&r->thread, NULL, lp_relay_thread, r) != 0) {
        pthread_mutex_lock(&app->rt.lock);
        if (app->rt.relay == r) {
            app->rt.relay = NULL;
            lp_set_state_locked(&app->rt, LP_STOPPED);
            lp_set_message_locked(&app->rt, "Proxy start failed");
        }
        pthread_mutex_unlock(&app->rt.lock);
        lp_relay_destroy(r);
        return -1;
    }

    pthread_mutex_lock(&app->rt.lock);
    if (app->rt.relay == r) {
        lp_set_state_locked(&app->rt, LP_RUNNING);
        lp_set_message_locked(&app->rt, "Proxy running");
    }
    pthread_mutex_unlock(&app->rt.lock);
    return 0;
}

static void lp_relay_request_stop(lp_relay_t *r) {
    if (!r) return;
    r->stop_flag = 1;
    if (r->wake_pipe[1] >= 0) (void)write(r->wake_pipe[1], "x", 1);
}

static int lp_runtime_stop(lp_app_t *app) {
    lp_relay_t *r = NULL;
    pthread_mutex_lock(&app->rt.lock);
    if (app->rt.relay == NULL) {
        lp_set_state_locked(&app->rt, LP_STOPPED);
        lp_set_message_locked(&app->rt, "Proxy already stopped");
        pthread_mutex_unlock(&app->rt.lock);
        return 0;
    }
    r = app->rt.relay;
    lp_set_state_locked(&app->rt, LP_STOPPING);
    lp_set_message_locked(&app->rt, "Proxy stopping...");
    pthread_mutex_unlock(&app->rt.lock);

    lp_relay_request_stop(r);
    pthread_join(r->thread, NULL);
    lp_relay_destroy(r);
    return 0;
}

static int lp_runtime_start(lp_app_t *app, const char *host, uint16_t port) {
    int running = 0;
    int same = 0;

    pthread_mutex_lock(&app->rt.lock);
    if ((!host || !host[0]) && app->rt.target_host[0]) {
        host = app->rt.target_host;
        if (!port) port = app->rt.target_port;
    }
    if ((!host || !host[0]) && app->cfg.remote_default_host[0]) {
        host = app->cfg.remote_default_host;
        if (!port) port = app->cfg.remote_default_port;
    }
    if (!host || !host[0]) {
        lp_set_message_locked(&app->rt, "Missing target host");
        pthread_mutex_unlock(&app->rt.lock);
        return -1;
    }
    if (!port) port = app->cfg.remote_default_port ? app->cfg.remote_default_port : 19132;
    running = (app->rt.relay != NULL);
    same = running &&
           app->rt.target_port == port &&
           strncmp(app->rt.target_host, host, sizeof(app->rt.target_host)) == 0;
    if (same) {
        lp_set_message_locked(&app->rt, "Proxy already running");
        pthread_mutex_unlock(&app->rt.lock);
        return 0;
    }
    pthread_mutex_unlock(&app->rt.lock);

    if (running) (void)lp_runtime_stop(app);
    return lp_relay_start(app, host, port);
}

static int lp_runtime_toggle(lp_app_t *app, const char *host, uint16_t port) {
    int running;
    pthread_mutex_lock(&app->rt.lock);
    running = (app->rt.relay != NULL);
    pthread_mutex_unlock(&app->rt.lock);
    return running ? lp_runtime_stop(app) : lp_runtime_start(app, host, port);
}

static void lp_iso8601(time_t ts, char *out, size_t out_sz) {
    struct tm tmv;
    memset(&tmv, 0, sizeof(tmv));
    gmtime_r(&ts, &tmv);
    strftime(out, out_sz, "%Y-%m-%dT%H:%M:%SZ", &tmv);
}

static void lp_json_escape(const char *src, char *out, size_t out_sz) {
    size_t j = 0;
    if (!out_sz) return;
    for (size_t i = 0; src && src[i] && j + 2 < out_sz; i++) {
        char c = src[i];
        if (c == '"' || c == '\\') {
            out[j++] = '\\';
            out[j++] = c;
        } else if ((unsigned char)c < 32) {
            continue;
        } else {
            out[j++] = c;
        }
    }
    out[j] = '\0';
}

static void lp_status_json(lp_app_t *app, char *out, size_t out_sz) {
    char ts[32], host[LP_MAX_HOST * 2 + 8], msg[LP_MSG_BUF * 2 + 8];
    lp_state_t st;
    char target_host[LP_MAX_HOST + 1];
    uint16_t target_port, local_port;
    char message[LP_MSG_BUF];
    time_t updated_at;

    pthread_mutex_lock(&app->rt.lock);
    st = app->rt.state;
    strncpy(target_host, app->rt.target_host, sizeof(target_host) - 1);
    target_host[sizeof(target_host) - 1] = '\0';
    target_port = app->rt.target_port;
    strncpy(message, app->rt.message, sizeof(message) - 1);
    message[sizeof(message) - 1] = '\0';
    updated_at = app->rt.updated_at;
    local_port = app->cfg.local_proxy_port;
    pthread_mutex_unlock(&app->rt.lock);

    lp_iso8601(updated_at, ts, sizeof(ts));
    lp_json_escape(target_host, host, sizeof(host));
    lp_json_escape(message, msg, sizeof(msg));
    if (target_host[0]) {
        snprintf(out, out_sz,
                 "{\"state\":\"%s\",\"localProxyPort\":%u,\"target\":{\"serverHost\":\"%s\",\"serverPort\":%u},\"updatedAt\":\"%s\",\"message\":\"%s\"}",
                 lp_state_name(st), (unsigned)local_port, host, (unsigned)target_port, ts, msg);
    } else {
        snprintf(out, out_sz,
                 "{\"state\":\"%s\",\"localProxyPort\":%u,\"target\":null,\"updatedAt\":\"%s\",\"message\":\"%s\"}",
                 lp_state_name(st), (unsigned)local_port, ts, msg);
    }
}

static int lp_http_send(int fd, int code, const char *text, const char *body) {
    char header[512];
    size_t body_len = body ? strlen(body) : 0;
    int n = snprintf(header, sizeof(header),
                     "HTTP/1.1 %d %s\r\n"
                     "Content-Type: application/json\r\n"
                     "Content-Length: %zu\r\n"
                     "Connection: close\r\n\r\n",
                     code, text, body_len);
    if (n < 0) return -1;
    (void)send(fd, header, (size_t)n, 0);
    if (body_len) (void)send(fd, body, body_len, 0);
    return 0;
}

static void lp_http_send_err(int fd, int code, const char *text, const char *err) {
    char esc[256];
    char body[320];
    lp_json_escape(err, esc, sizeof(esc));
    snprintf(body, sizeof(body), "{\"error\":\"%s\"}", esc);
    (void)lp_http_send(fd, code, text, body);
}

static int lp_http_read(int fd, char *buf, size_t buf_sz, size_t *out_len) {
    size_t used = 0;
    while (used + 1 < buf_sz) {
        ssize_t n = recv(fd, buf + used, buf_sz - used - 1, 0);
        if (n == 0) break;
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        used += (size_t)n;
        buf[used] = '\0';
        char *hdr_end = strstr(buf, "\r\n\r\n");
        if (hdr_end) {
            char *cl = NULL;
            long need = 0;
            for (char *p = buf; p < hdr_end; p++) {
                if (strncasecmp(p, "Content-Length:", 15) == 0) {
                    cl = p + 15;
                    break;
                }
            }
            if (cl) need = strtol(cl, NULL, 10);
            if (need < 0) need = 0;
            if ((size_t)(hdr_end + 4 - buf) + (size_t)need <= used) break;
        }
    }
    *out_len = used;
    return 0;
}

static int lp_http_parse(char *buf, lp_http_req_t *req) {
    char *save = NULL, *line = NULL, *hdr_end = NULL;
    size_t content_length = 0;
    memset(req, 0, sizeof(*req));
    hdr_end = strstr(buf, "\r\n\r\n");
    if (!hdr_end) return -1;
    *hdr_end = '\0';
    req->body = hdr_end + 4;
    line = strtok_r(buf, "\r\n", &save);
    if (!line) return -1;
    if (sscanf(line, "%7s %127s", req->method, req->path) != 2) return -1;
    while ((line = strtok_r(NULL, "\r\n", &save)) != NULL) {
        if (strncasecmp(line, "Authorization:", 14) == 0) {
            strncpy(req->auth, lp_skip_ws(line + 14), sizeof(req->auth) - 1);
        } else if (strncasecmp(line, "Content-Length:", 15) == 0) {
            content_length = (size_t)strtoul(line + 15, NULL, 10);
        }
    }
    req->body_len = content_length;
    return 0;
}

static int lp_http_authorized(lp_app_t *app, lp_http_req_t *req) {
    char expected[LP_MAX_TOKEN + 16];
    if (!app->cfg.control_auth_token[0]) return 1;
    snprintf(expected, sizeof(expected), "Bearer %s", app->cfg.control_auth_token);
    return strcmp(req->auth, expected) == 0;
}

static void lp_parse_start_body(lp_http_req_t *req, char *host, size_t host_sz, uint16_t *port) {
    char body[8192];
    long v;
    if (!req->body || req->body_len == 0 || req->body_len >= sizeof(body)) return;
    memcpy(body, req->body, req->body_len);
    body[req->body_len] = '\0';
    if (host && host_sz) lp_json_get_string(body, "serverHost", host, host_sz);
    if (port && lp_json_get_int(body, "serverPort", &v) && v > 0 && v <= 65535) *port = (uint16_t)v;
}

static void lp_http_handle(lp_app_t *app, int fd, lp_http_req_t *req) {
    char json[1024];
    char host[LP_MAX_HOST + 1] = {0};
    uint16_t port = 0;

    if (!lp_http_authorized(app, req)) {
        lp_http_send_err(fd, 401, "Unauthorized", "unauthorized");
        return;
    }

    if (strcmp(req->method, "GET") == 0 && strcmp(req->path, "/healthz") == 0) {
        (void)lp_http_send(fd, 200, "OK", "{\"ok\":true}");
        return;
    }
    if (strcmp(req->method, "GET") == 0 && strcmp(req->path, "/status") == 0) {
        lp_status_json(app, json, sizeof(json));
        (void)lp_http_send(fd, 200, "OK", json);
        return;
    }

    if (strcmp(req->method, "POST") == 0 &&
        (strcmp(req->path, "/proxy/start") == 0 || strcmp(req->path, "/proxy/toggle") == 0)) {
        lp_parse_start_body(req, host, sizeof(host), &port);
    }

    if (strcmp(req->method, "POST") == 0 && strcmp(req->path, "/proxy/start") == 0) {
        if (lp_runtime_start(app, host, port) != 0) {
            lp_http_send_err(fd, 500, "Internal Server Error", "start_failed");
            return;
        }
        lp_status_json(app, json, sizeof(json));
        (void)lp_http_send(fd, 200, "OK", json);
        return;
    }
    if (strcmp(req->method, "POST") == 0 && strcmp(req->path, "/proxy/stop") == 0) {
        (void)lp_runtime_stop(app);
        lp_status_json(app, json, sizeof(json));
        (void)lp_http_send(fd, 200, "OK", json);
        return;
    }
    if (strcmp(req->method, "POST") == 0 && strcmp(req->path, "/proxy/toggle") == 0) {
        if (lp_runtime_toggle(app, host, port) != 0) {
            lp_http_send_err(fd, 500, "Internal Server Error", "toggle_failed");
            return;
        }
        lp_status_json(app, json, sizeof(json));
        (void)lp_http_send(fd, 200, "OK", json);
        return;
    }
    lp_http_send_err(fd, 404, "Not Found", "not_found");
}

static int lp_make_http_listener(const char *host, uint16_t port) {
    struct addrinfo hints, *res = NULL, *it;
    char port_s[16];
    int fd = -1, one = 1;
    snprintf(port_s, sizeof(port_s), "%u", (unsigned)port);
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    if (getaddrinfo(host, port_s, &hints, &res) != 0) return -1;
    for (it = res; it; it = it->ai_next) {
        fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd < 0) continue;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (bind(fd, it->ai_addr, it->ai_addrlen) == 0 && listen(fd, 16) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

static void lp_http_server(lp_app_t *app) {
    int s = lp_make_http_listener(app->cfg.control_bind_host, app->cfg.control_port);
    if (s < 0) {
        fprintf(stderr, "[luminaproxyd] failed to bind %s:%u\n",
                app->cfg.control_bind_host, (unsigned)app->cfg.control_port);
        return;
    }
    lp_log("HTTP control server listening on http://%s:%u", app->cfg.control_bind_host, (unsigned)app->cfg.control_port);

    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0) {
            if (errno == EINTR) continue;
            lp_log("accept error: %s", strerror(errno));
            continue;
        }
        char buf[LP_HTTP_BUF];
        size_t len = 0;
        lp_http_req_t req;
        if (lp_http_read(c, buf, sizeof(buf), &len) != 0 || len == 0) {
            lp_http_send_err(c, 400, "Bad Request", "invalid_http_request");
            close(c);
            continue;
        }
        buf[(len < sizeof(buf)) ? len : (sizeof(buf) - 1)] = '\0';
        if (lp_http_parse(buf, &req) != 0) {
            lp_http_send_err(c, 400, "Bad Request", "invalid_http_request");
            close(c);
            continue;
        }
        lp_http_handle(app, c, &req);
        close(c);
    }
}

int main(int argc, char **argv) {
    const char *config_path = "/var/mobile/Library/Preferences/com.project.lumina.proxyd.json";
    lp_app_t app;

    signal(SIGPIPE, SIG_IGN);
    if (argc > 1 && argv[1] && argv[1][0]) config_path = argv[1];

    memset(&app, 0, sizeof(app));
    if (lp_config_load(config_path, &app.cfg) != 0) {
        fprintf(stderr, "[luminaproxyd] failed to load config: %s\n", config_path);
        return 1;
    }
    lp_runtime_init(&app.rt, &app.cfg);

    lp_log("deviceId=%s localProxyPort=%u remoteDefault=%s:%u",
           app.cfg.device_id,
           (unsigned)app.cfg.local_proxy_port,
           app.cfg.remote_default_host[0] ? app.cfg.remote_default_host : "(unset)",
           (unsigned)app.cfg.remote_default_port);

    lp_http_server(&app);

    (void)lp_runtime_stop(&app);
    lp_runtime_destroy(&app.rt);
    return 0;
}
