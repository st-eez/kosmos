#include "KosmosBar.h"

#include <servers/bootstrap.h>
#include <string.h>

typedef struct {
    mach_msg_header_t header;
    mach_msg_size_t count;
    mach_msg_ool_descriptor_t payload;
} bar_message;

typedef struct {
    bar_message message;
    mach_msg_trailer_t trailer;
} bar_reply;

static mach_port_t cached_port = MACH_PORT_NULL;

static mach_port_t look_up(const char *name) {
    mach_port_t bootstrap, port = MACH_PORT_NULL;
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap) != KERN_SUCCESS) return MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap, name, &port) != KERN_SUCCESS) port = MACH_PORT_NULL;
    mach_port_deallocate(mach_task_self(), bootstrap);
    return port;
}

static kern_return_t send(mach_port_t port, mach_port_t reply, const char *payload, uint32_t length) {
    bar_message message = {0};
    message.header.msgh_remote_port = port;
    message.header.msgh_local_port = reply;
    message.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND,
                                                  reply ? MACH_MSG_TYPE_MAKE_SEND : 0, 0, MACH_MSGH_BITS_COMPLEX);
    message.header.msgh_size = sizeof message;
    message.count = 1;
    message.payload.address = (void *)payload;
    message.payload.size = length;
    message.payload.copy = MACH_MSG_VIRTUAL_COPY;
    message.payload.deallocate = false;
    message.payload.type = MACH_MSG_OOL_DESCRIPTOR;
    return mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message, 0,
                    MACH_PORT_NULL, 0, MACH_PORT_NULL);
}

kern_return_t kosmos_bar_send(const char *name, const char *payload, uint32_t length) {
    if (cached_port == MACH_PORT_NULL) cached_port = look_up(name);
    if (cached_port == MACH_PORT_NULL) return MACH_SEND_INVALID_DEST;
    kern_return_t result = send(cached_port, MACH_PORT_NULL, payload, length);
    if (result == MACH_SEND_INVALID_DEST) {
        mach_port_deallocate(mach_task_self(), cached_port);
        cached_port = look_up(name);
        if (cached_port == MACH_PORT_NULL) return MACH_SEND_INVALID_DEST;
        result = send(cached_port, MACH_PORT_NULL, payload, length);
    }
    return result;
}

int kosmos_bar_query(const char *name, const char *payload, uint32_t length,
                     char *reply, uint32_t capacity, uint32_t timeout_ms) {
    mach_port_t port = look_up(name);
    if (port == MACH_PORT_NULL) return -1;
    mach_port_t receive = MACH_PORT_NULL;
    int copied = -1;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &receive) != KERN_SUCCESS) goto done;
    if (send(port, receive, payload, length) != KERN_SUCCESS) goto done;
    bar_reply answer = {0};
    if (mach_msg(&answer.message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof answer, receive,
                 timeout_ms, MACH_PORT_NULL) != KERN_SUCCESS) goto done;
    uint32_t size = answer.message.payload.size < capacity ? answer.message.payload.size : capacity;
    if (answer.message.payload.address) memcpy(reply, answer.message.payload.address, size);
    copied = (int)size;
    mach_msg_destroy(&answer.message.header);
done:
    if (receive != MACH_PORT_NULL) mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), port);
    return copied;
}
