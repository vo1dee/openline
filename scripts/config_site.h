/* Openline PJSIP build configuration. Copied to pjlib/include/pj/config_site.h
 * by scripts/build-native-deps.sh. */
#pragma once

/* Desktop-class limits: all enabled accounts stay registered at once. */
#define PJSUA_MAX_ACC                       16
#define PJSUA_MAX_CALLS                     8
#define PJ_IOQUEUE_MAX_HANDLES              1024
#define PJSIP_MAX_TSX_COUNT                 (640 * 8)
#define PJSIP_MAX_DIALOG_COUNT              (640 * 8)
#define PJSIP_UDP_SO_SNDBUF_SIZE            (256 * 1024)
#define PJSIP_UDP_SO_RCVBUF_SIZE            (256 * 1024)
#define PJMEDIA_CONF_USE_SWITCH_BOARD       0

#define PJ_HAS_IPV6                         1
#define PJMEDIA_HAS_SRTP                    1
#define PJMEDIA_HAS_VIDEO                   0
#define PJ_DEBUG                            0
#define PJ_LOG_MAX_LEVEL                    5
#define PJSIP_AUTH_AUTO_SEND_NEXT           1

/* TLS via Network.framework: no OpenSSL to bundle, system trust store. */
#define PJ_HAS_SSL_SOCK                     1
#undef  PJ_SSL_SOCK_IMP
#define PJ_SSL_SOCK_IMP                     PJ_SSL_SOCK_IMP_APPLE

/* Echo cancellation: WebRTC AEC3 is selected at runtime by the bridge. */
#define PJMEDIA_HAS_WEBRTC_AEC3             1
#define PJMEDIA_HAS_SPEEX_AEC               0
