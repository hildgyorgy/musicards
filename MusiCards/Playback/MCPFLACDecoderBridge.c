#include "MCPFLACDecoderBridge.h"

#include <FLAC/stream_decoder.h>
#include <stdbool.h>
#include <stdlib.h>

enum {
    MCPFLAC_CALLBACK_CONTINUE = 0,
    MCPFLAC_CALLBACK_END = 1,
    MCPFLAC_CALLBACK_ABORT = 2
};

struct MCPFLACDecoder {
    FLAC__StreamDecoder *decoder;
    bool initialized;
    MCPFLACReadCallback readCallback;
    MCPFLACSeekCallback seekCallback;
    MCPFLACTellCallback tellCallback;
    MCPFLACLengthCallback lengthCallback;
    MCPFLACEofCallback eofCallback;
    MCPFLACWriteCallback writeCallback;
    MCPFLACMetadataCallback metadataCallback;
    MCPFLACErrorCallback errorCallback;
    void *context;
    int32_t *interleavedSamples;
    size_t interleavedCapacity;
};

static FLAC__StreamDecoderReadStatus MCPRead(
    const FLAC__StreamDecoder *decoder,
    FLAC__byte buffer[],
    size_t *bytes,
    void *clientData
) {
    (void)decoder;
    MCPFLACDecoder *wrapper = clientData;
    const int result = wrapper->readCallback(
        wrapper->context,
        buffer,
        bytes
    );
    switch (result) {
        case MCPFLAC_CALLBACK_CONTINUE:
            return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
        case MCPFLAC_CALLBACK_END:
            return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
        default:
            return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
}

static FLAC__StreamDecoderSeekStatus MCPSearch(
    const FLAC__StreamDecoder *decoder,
    FLAC__uint64 offset,
    void *clientData
) {
    (void)decoder;
    MCPFLACDecoder *wrapper = clientData;
    return wrapper->seekCallback(wrapper->context, offset) == 0
        ? FLAC__STREAM_DECODER_SEEK_STATUS_OK
        : FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;
}

static FLAC__StreamDecoderTellStatus MCPTell(
    const FLAC__StreamDecoder *decoder,
    FLAC__uint64 *offset,
    void *clientData
) {
    (void)decoder;
    MCPFLACDecoder *wrapper = clientData;
    return wrapper->tellCallback(wrapper->context, offset) == 0
        ? FLAC__STREAM_DECODER_TELL_STATUS_OK
        : FLAC__STREAM_DECODER_TELL_STATUS_ERROR;
}

static FLAC__StreamDecoderLengthStatus MCPLength(
    const FLAC__StreamDecoder *decoder,
    FLAC__uint64 *length,
    void *clientData
) {
    (void)decoder;
    MCPFLACDecoder *wrapper = clientData;
    return wrapper->lengthCallback(wrapper->context, length) == 0
        ? FLAC__STREAM_DECODER_LENGTH_STATUS_OK
        : FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR;
}

static FLAC__bool MCPEof(
    const FLAC__StreamDecoder *decoder,
    void *clientData
) {
    (void)decoder;
    MCPFLACDecoder *wrapper = clientData;
    return wrapper->eofCallback(wrapper->context);
}

static FLAC__StreamDecoderWriteStatus MCPWrite(
    const FLAC__StreamDecoder *decoder,
    const FLAC__Frame *frame,
    const FLAC__int32 * const buffer[],
    void *clientData
) {
    (void)decoder;
    MCPFLACDecoder *wrapper = clientData;
    const uint32_t frameCount = frame->header.blocksize;
    const uint32_t channels = frame->header.channels;
    const size_t sampleCount = (size_t)frameCount * channels;

    if (sampleCount > wrapper->interleavedCapacity) {
        int32_t *samples = realloc(
            wrapper->interleavedSamples,
            sampleCount * sizeof(int32_t)
        );
        if (samples == NULL) {
            wrapper->errorCallback(
                wrapper->context,
                FLAC__STREAM_DECODER_ERROR_STATUS_UNPARSEABLE_STREAM
            );
            return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
        }
        wrapper->interleavedSamples = samples;
        wrapper->interleavedCapacity = sampleCount;
    }

    for (uint32_t frameIndex = 0; frameIndex < frameCount; frameIndex++) {
        for (uint32_t channel = 0; channel < channels; channel++) {
            wrapper->interleavedSamples[
                (size_t)frameIndex * channels + channel
            ] = buffer[channel][frameIndex];
        }
    }

    return wrapper->writeCallback(
        wrapper->context,
        frameCount,
        channels,
        frame->header.bits_per_sample,
        wrapper->interleavedSamples
    ) == 0
        ? FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
        : FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
}

static void MCPMetadata(
    const FLAC__StreamDecoder *decoder,
    const FLAC__StreamMetadata *metadata,
    void *clientData
) {
    (void)decoder;
    if (metadata->type != FLAC__METADATA_TYPE_STREAMINFO) {
        return;
    }
    MCPFLACDecoder *wrapper = clientData;
    wrapper->metadataCallback(
        wrapper->context,
        metadata->data.stream_info.sample_rate,
        metadata->data.stream_info.channels,
        metadata->data.stream_info.bits_per_sample,
        metadata->data.stream_info.total_samples
    );
}

static void MCPError(
    const FLAC__StreamDecoder *decoder,
    FLAC__StreamDecoderErrorStatus status,
    void *clientData
) {
    (void)decoder;
    MCPFLACDecoder *wrapper = clientData;
    wrapper->errorCallback(wrapper->context, (int)status);
}

MCPFLACDecoder *MCPFLACDecoderCreate(void) {
    MCPFLACDecoder *wrapper = calloc(1, sizeof(MCPFLACDecoder));
    if (wrapper == NULL) {
        return NULL;
    }
    wrapper->decoder = FLAC__stream_decoder_new();
    if (wrapper->decoder == NULL) {
        free(wrapper);
        return NULL;
    }
    return wrapper;
}

int MCPFLACDecoderInitialize(
    MCPFLACDecoder *wrapper,
    MCPFLACReadCallback readCallback,
    MCPFLACSeekCallback seekCallback,
    MCPFLACTellCallback tellCallback,
    MCPFLACLengthCallback lengthCallback,
    MCPFLACEofCallback eofCallback,
    MCPFLACWriteCallback writeCallback,
    MCPFLACMetadataCallback metadataCallback,
    MCPFLACErrorCallback errorCallback,
    void *context
) {
    if (wrapper == NULL || readCallback == NULL || writeCallback == NULL
        || metadataCallback == NULL || errorCallback == NULL) {
        return -1;
    }
    wrapper->readCallback = readCallback;
    wrapper->seekCallback = seekCallback;
    wrapper->tellCallback = tellCallback;
    wrapper->lengthCallback = lengthCallback;
    wrapper->eofCallback = eofCallback;
    wrapper->writeCallback = writeCallback;
    wrapper->metadataCallback = metadataCallback;
    wrapper->errorCallback = errorCallback;
    wrapper->context = context;

    const FLAC__StreamDecoderInitStatus status =
        FLAC__stream_decoder_init_stream(
        wrapper->decoder,
        MCPRead,
        MCPSearch,
        MCPTell,
        MCPLength,
        MCPEof,
        MCPWrite,
        MCPMetadata,
        MCPError,
        wrapper
    );
    wrapper->initialized = status == FLAC__STREAM_DECODER_INIT_STATUS_OK;
    return (int)status;
}

bool MCPFLACDecoderProcessMetadata(MCPFLACDecoder *wrapper) {
    return wrapper != NULL
        && FLAC__stream_decoder_process_until_end_of_metadata(
            wrapper->decoder
        );
}

bool MCPFLACDecoderProcessSingle(MCPFLACDecoder *wrapper) {
    return wrapper != NULL
        && FLAC__stream_decoder_process_single(wrapper->decoder);
}

bool MCPFLACDecoderSeekAbsolute(
    MCPFLACDecoder *wrapper,
    uint64_t frame
) {
    return wrapper != NULL
        && FLAC__stream_decoder_seek_absolute(wrapper->decoder, frame);
}

bool MCPFLACDecoderHasEnded(const MCPFLACDecoder *wrapper) {
    return wrapper != NULL
        && FLAC__stream_decoder_get_state(wrapper->decoder)
            == FLAC__STREAM_DECODER_END_OF_STREAM;
}

void MCPFLACDecoderDestroy(MCPFLACDecoder *wrapper) {
    if (wrapper == NULL) {
        return;
    }
    if (wrapper->initialized) {
        FLAC__stream_decoder_finish(wrapper->decoder);
    }
    FLAC__stream_decoder_delete(wrapper->decoder);
    free(wrapper->interleavedSamples);
    free(wrapper);
}
