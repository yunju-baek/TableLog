#ifndef HWAJA_ENGINE_H
#define HWAJA_ENGINE_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HNEngine HNEngine;
enum { HN_OK = 0, HN_INVALID_ARGUMENT = 1, HN_INVALID_STATE = 2, HN_RUNTIME_ERROR = 3 };

// All functions, including destruction, must run on the same serial worker.
// Models are retained across sessions. right_context must be 3 or 13.
// Returns NULL on failure; read hn_engine_last_error(NULL) on the same thread.
HNEngine *hn_engine_create(const char *asr_model, const char *diar_model, int32_t right_context);
// diar_profile: 0 = official v3-streaming; 1 = app long-FIFO geometry.
HNEngine *hn_engine_create_configured(const char *asr_model, const char *diar_model,
                                     int32_t right_context, int32_t diar_profile);
int32_t hn_engine_start_configured(HNEngine *engine, const char *const *phrases,
                                  size_t phrase_count, float boost, int32_t punctuation);
// Starts a fresh session and discards any previous session data.
int32_t hn_engine_start(HNEngine *engine);
// Starts a fresh session with local RNNT contextual word boosting.
// Copies UTF-8 phrases synchronously; the caller may release them on return.
// Limits: 128 phrases, 512 bytes per phrase, 32768 bytes total; boost 0.1..5.0.
// Requires the ASR GGUF's matching embedded SentencePiece tokenizer.
// Context applies for this session; call a start function for the next context.
int32_t hn_engine_start_with_context(HNEngine *engine, const char *const *phrases,
                                    size_t phrase_count, float boost);
// Copies/consumes mono 16 kHz float PCM synchronously. 0..1600 finite samples.
// Runs available inference and refreshes provisional speaker labels.
int32_t hn_engine_push(HNEngine *engine, const float *samples, size_t count);
// Flushes remaining audio, retaining the complete final snapshot. Idempotent.
int32_t hn_engine_finish(HNEngine *engine);
// Closes the session and clears its snapshot; retains the loaded models.
int32_t hn_engine_reset(HNEngine *engine);
// Borrowed UTF-8 JSON; copy immediately before any subsequent engine call.
// Returns NULL on failure. Time units are seconds; speaker 0 = pending,
// speakers 1..8 are session-local anonymous identifiers.
// speaker_activity samples the same diarizer on a 20 ms grid independently of
// ASR words. It is a dominant-speaker timeline including silence, not VAD;
// use it to label recognized words. speaker_activity_kind states this contract.
const char *hn_engine_snapshot_json(HNEngine *engine);
// Borrowed UTF-8 error. Stable code prefix; detail may originate upstream.
const char *hn_engine_last_error(const HNEngine *engine);
void hn_engine_destroy(HNEngine *engine);

#ifdef __cplusplus
}
#endif
#endif
