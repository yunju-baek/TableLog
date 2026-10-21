#include "HwajaEngine.h"
#include "recognizer.h"
#include "model.h"
#include <algorithm>
#include <cmath>
#include <exception>
#include <iomanip>
#include <locale>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace asr = nemo_speech::asr;
namespace {
thread_local std::string creation_error;
std::string quote(const std::string &s) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(c) << std::dec;
        else out << c;
    }
    out << '"';
    return out.str();
}
bool punctuation_only(const std::string &text) {
    return !text.empty() && text.find_first_not_of(".,!?;:%)]}") == std::string::npos;
}
void append_text(std::string &dest, const std::string &text) {
    if (text.empty()) return;
    if (!dest.empty() && !punctuation_only(text) && dest.back() != ' ') dest += ' ';
    dest += text;
}
bool sentence_end(const std::string &text) {
    return !text.empty() && std::string(".!?").find(text.back()) != std::string::npos;
}
}

struct HNEngine {
    std::unique_ptr<asr::Recognizer> recognizer;
    std::unique_ptr<asr::RecognitionStream> stream;
    std::vector<asr::Result> committed;
    asr::Result interim;
    bool has_interim = false;
    bool finished = false;
    uint64_t samples = 0;
    uint64_t revision = 0;
    double processed = 0;
    double stable = 0;
    int right_context = 3;
    int diar_profile = 1;
    bool punctuation = true;
    size_t context_phrase_count = 0;
    size_t context_token_count = 0;
    float context_boost = 0;
    // Dominant diarizer label on a 20 ms grid, sampled independently of ASR
    // words through the official retagging API. This includes silence; callers
    // use it only to label independently recognized words, never as speech VAD.
    std::vector<int8_t> speaker_timeline;
    size_t speaker_timeline_stable_frames = 0;
    std::string error;
    std::string json;

    void clear_session() {
        stream.reset();
        committed.clear();
        interim = {};
        has_interim = false;
        finished = false;
        samples = 0;
        processed = 0;
        stable = 0;
        context_phrase_count = 0;
        context_token_count = 0;
        context_boost = 0;
        speaker_timeline.clear();
        speaker_timeline_stable_frames = 0;
        ++revision;
        json.clear();
    }

    void accept(asr::Result value) {
        processed = std::max(processed, double(value.audio_processed));
        if (!value.late_punctuation.empty() && !committed.empty()) {
            auto &last = committed.back();
            if (!last.alternatives.empty()) {
                auto &alt = last.alternatives.front();
                alt.transcript += value.late_punctuation;
                if (!alt.words.empty()) alt.words.back().word += value.late_punctuation;
            }
        }
        if (value.is_final) {
            if (!value.alternatives.empty() && !value.alternatives.front().transcript.empty())
                committed.push_back(std::move(value));
            has_interim = false;
            interim = {};
        } else {
            interim = std::move(value);
            has_interim = true;
        }
        ++revision;
    }

    void refresh() {
        // The official diarizer can revise earlier labels within its mutable
        // window. Retag both committed utterances and the current hypothesis.
        for (auto &value : committed) {
            if (value.alternatives.empty()) continue;
            const auto &words = value.alternatives.front().words;
            if (!words.empty() && words.back().start_time / 1000.0 >= stable)
                stream->refresh_speaker_tags(value);
        }
        if (has_interim) stream->refresh_speaker_tags(interim);
        refresh_speaker_timeline();
        stable = std::max(stable, stream->stable_speaker_time());
    }

    void refresh_speaker_timeline() {
        const double duration = samples / 16000.0;
        const double frontier = finished ? duration : std::min(duration, processed);
        const size_t frames = static_cast<size_t>(std::ceil(frontier / 0.020));
        const size_t first = std::min(speaker_timeline_stable_frames, frames);
        speaker_timeline.resize(frames, 0);
        asr::Result probe;
        probe.alternatives.emplace_back();
        auto &words = probe.alternatives.front().words;
        words.resize(frames - first);
        for (size_t i = first; i < frames; ++i) {
            auto &word = words[i - first];
            word.start_time = static_cast<int32_t>(i * 20);
            word.end_time = static_cast<int32_t>(std::min((i + 1) * 20.0, duration * 1000.0));
        }
        stream->refresh_speaker_tags(probe);
        for (size_t i = first; i < frames; ++i)
            speaker_timeline[i] = static_cast<int8_t>(words[i - first].speaker_tag);
        speaker_timeline_stable_frames = std::min(frames, static_cast<size_t>(
            std::floor(std::max(0.0, stream->stable_speaker_time()) / 0.020)));
    }

    void drain() {
        while (auto result = stream->next()) accept(std::move(*result));
        refresh();
    }

    void make_json() {
        std::vector<asr::Word> words;
        std::string text;
        auto gather = [&](const asr::Result &result) {
            if (result.alternatives.empty()) return;
            const auto &alt = result.alternatives.front();
            append_text(text, alt.transcript);
            words.insert(words.end(), alt.words.begin(), alt.words.end());
        };
        for (const auto &result : committed) gather(result);
        if (has_interim) gather(interim);

        struct Segment { size_t id; int speaker; double start, end; std::string text; };
        std::vector<Segment> segments;
        for (size_t i = 0; i < words.size(); ++i) {
            const auto &word = words[i];
            if (word.word.empty()) continue;
            const double start = std::max(0.0, word.start_time / 1000.0);
            const double end = std::max(start, word.end_time / 1000.0);
            const bool new_turn = segments.empty() || segments.back().speaker != word.speaker_tag ||
                start - segments.back().end > 0.85 || sentence_end(segments.back().text) ||
                end - segments.back().start > 15.0;
            if (new_turn) segments.push_back({i, word.speaker_tag, start, end, word.word});
            else {
                append_text(segments.back().text, word.word);
                segments.back().end = std::max(segments.back().end, end);
            }
        }

        std::ostringstream out;
        out.imbue(std::locale::classic());
        out << std::fixed << std::setprecision(3)
            << "{\"schema_version\":1,\"language\":\"ko-KR\",\"backend\":\"Metal\","
            << "\"engine\":\"NVIDIA/NeMo-Speech.cpp\",\"engine_version\":\"0.2.0\",\"engine_revision\":\"6a3ca369370782acee0dd155e34394ba60b920c4\","
            << "\"endpointing\":true,\"finalized_utterances\":" << committed.size() << ','
            << "\"speaker_capacity\":8,\"right_context\":" << right_context
            << ",\"diar_profile\":" << diar_profile << ",\"automatic_punctuation\":" << (punctuation ? "true" : "false")
            << ",\"context_phrase_count\":" << context_phrase_count
            << ",\"context_token_count\":" << context_token_count
            << ",\"context_boost\":" << context_boost
            << ",\"revision\":" << revision << ",\"audio_seconds\":" << samples / 16000.0
            << ",\"processed_seconds\":" << processed << ",\"stable_speaker_seconds\":" << stable
            << ",\"is_final\":" << (finished ? "true" : "false")
            << ",\"state\":" << quote(finished ? "finished" : stream ? "recording" : "ready")
            << ",\"text\":" << quote(text) << ",\"words\":[";
        for (size_t i = 0; i < words.size(); ++i) {
            const auto &word = words[i];
            if (i) out << ',';
            out << "{\"text\":" << quote(word.word) << ",\"start\":" << word.start_time / 1000.0
                << ",\"end\":" << word.end_time / 1000.0 << ",\"speaker\":" << word.speaker_tag << '}';
        }
        out << "],\"segments\":[";
        for (size_t i = 0; i < segments.size(); ++i) {
            const auto &segment = segments[i];
            if (i) out << ',';
            out << "{\"id\":" << segment.id << ",\"speaker\":" << segment.speaker
                << ",\"start\":" << segment.start << ",\"end\":" << segment.end
                << ",\"text\":" << quote(segment.text) << '}';
        }
        out << "],\"speaker_activity_kind\":\"dominant_20ms_including_silence\",\"speaker_activity\":[";
        bool first_activity = true;
        for (size_t i = 0; i < speaker_timeline.size();) {
            const size_t first = i;
            const int speaker = speaker_timeline[i++];
            while (i < speaker_timeline.size() && speaker_timeline[i] == speaker) ++i;
            if (speaker <= 0) continue;
            if (!first_activity) out << ',';
            first_activity = false;
            out << "{\"speaker\":" << speaker << ",\"start\":" << first * 0.020
                << ",\"end\":" << std::min(i * 0.020, samples / 16000.0) << '}';
        }
        out << "]}";
        json = out.str();
    }
};

namespace {
template<class Fn> int32_t guarded(HNEngine *engine, Fn fn) {
    if (!engine) { creation_error = "HN_INVALID_ARGUMENT: engine is null"; return HN_INVALID_ARGUMENT; }
    try {
        engine->error.clear();
        fn();
        return HN_OK;
    } catch (const std::invalid_argument &e) {
        engine->error = std::string("HN_INVALID_ARGUMENT: ") + e.what();
        return HN_INVALID_ARGUMENT;
    } catch (const std::logic_error &e) {
        engine->error = std::string("HN_INVALID_STATE: ") + e.what();
        return HN_INVALID_STATE;
    } catch (const std::exception &e) {
        engine->error = std::string("HN_RUNTIME_ERROR: ") + e.what();
        return HN_RUNTIME_ERROR;
    } catch (...) {
        engine->error = "HN_RUNTIME_ERROR: unknown native exception";
        return HN_RUNTIME_ERROR;
    }
}
}

extern "C" HNEngine *hn_engine_create(const char *asr_model, const char *diar_model, int32_t right_context) {
    return hn_engine_create_configured(asr_model, diar_model, right_context, 1);
}

extern "C" HNEngine *hn_engine_create_configured(const char *asr_model, const char *diar_model, int32_t right_context, int32_t diar_profile) {
    try {
        creation_error.clear();
        if (!asr_model || !*asr_model || !diar_model || !*diar_model)
            throw std::invalid_argument("both model paths are required");
        if (right_context != 3 && right_context != 13)
            throw std::invalid_argument("right_context must be 3 or 13");
        if (diar_profile != 0 && diar_profile != 1) throw std::invalid_argument("diar_profile must be 0 or 1");
        auto engine = std::make_unique<HNEngine>();
        asr::RecognizerConfig config;
        config.backend.gpu = 0;
        config.model.path = asr_model;
        config.streaming.rnnt_right_context = right_context;
        // v0.2.0 preserves decoder context across utterance boundaries.
        config.endpointing.enable = true;
        config.batching.enabled = false;
        config.diar.model_path = diar_model;
        config.diar.geometry.chunk_len = 14;
        config.diar.geometry.chunk_left_context = 0;
        config.diar.geometry.chunk_right_context = 1;
        config.diar.geometry.fifo_len = 264;
        config.diar.geometry.spkcache_len = 264;
        config.diar.geometry.spkcache_update_period = 222;
        if (diar_profile == 0) config.diar.preset = "v3-streaming";
        engine->diar_profile = diar_profile;
        engine->recognizer = std::make_unique<asr::Recognizer>(config);
        if (!engine->recognizer->diar_model() || engine->recognizer->diar_model()->cfg().num_speakers != 8)
            throw std::invalid_argument("an eight-speaker Nemotron-3 diarization model is required");
        engine->right_context = right_context;
        return engine.release();
    } catch (const std::invalid_argument &e) {
        creation_error = std::string("HN_INVALID_ARGUMENT: ") + e.what();
    } catch (const std::exception &e) {
        creation_error = std::string("HN_RUNTIME_ERROR: ") + e.what();
    } catch (...) {
        creation_error = "HN_RUNTIME_ERROR: unknown native exception";
    }
    return nullptr;
}

extern "C" int32_t hn_engine_start(HNEngine *engine) {
    return hn_engine_start_with_context(engine, nullptr, 0, 1.0f);
}

extern "C" int32_t hn_engine_start_with_context(HNEngine *engine, const char *const *phrases,
                                                size_t phrase_count, float boost) {
    return hn_engine_start_configured(engine, phrases, phrase_count, boost, 1);
}

extern "C" int32_t hn_engine_start_configured(HNEngine *engine, const char *const *phrases,
                                             size_t phrase_count, float boost, int32_t punctuation) {
    return guarded(engine, [&] {
        if (punctuation != 0 && punctuation != 1) throw std::invalid_argument("punctuation must be 0 or 1");
        if (phrase_count > 128 || (phrase_count && !phrases))
            throw std::invalid_argument("context requires at most 128 UTF-8 phrases");
        if (phrase_count && (!std::isfinite(boost) || boost < 0.1f || boost > 5.0f))
            throw std::invalid_argument("context boost must be finite and between 0.1 and 5.0");
        asr::AsrRequestOptions::Boost context;
        context.boost = boost;
        size_t total_bytes = 0;
        size_t total_tokens = 0;
        auto *rnnt = dynamic_cast<asr::RnntModel *>(engine->recognizer->model());
        if (phrase_count && (!rnnt || !rnnt->embedded_tokenizer()))
            throw std::logic_error("context requires the matching embedded SentencePiece tokenizer in the ASR GGUF");
        for (size_t i = 0; i < phrase_count; ++i) {
            if (!phrases[i]) throw std::invalid_argument("context phrase is null");
            std::string phrase(phrases[i]);
            if (phrase.empty() || phrase.size() > 512 || phrase.find_first_not_of(" \t\r\n") == std::string::npos)
                throw std::invalid_argument("context phrases require 1..512 UTF-8 bytes of text");
            total_bytes += phrase.size();
            if (total_bytes > 32768) throw std::invalid_argument("context phrases exceed 32768 UTF-8 bytes");
            // The upstream decoder treats these strings as unsupported class
            // hints, so reject them instead of reporting an active phrase.
            if (phrase.size() > 1 && phrase.front() == '$' &&
                phrase.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZ_", 1) == std::string::npos)
                throw std::invalid_argument("context requires literal phrases; class hints are unsupported");
            if (std::find(context.phrases.begin(), context.phrases.end(), phrase) != context.phrases.end()) continue;
            const auto tokens = rnnt->encode_phrase(phrase);
            if (tokens.empty()) throw std::invalid_argument("context phrase could not be tokenized by the ASR model");
            total_tokens += tokens.size();
            context.phrases.push_back(std::move(phrase));
        }
        asr::AsrRequestOptions options;
        options.language_code = "ko-KR";
        options.enable_word_time_offsets = true;
        options.enable_automatic_punctuation = punctuation != 0;
        engine->punctuation = punctuation != 0;
        options.enable_speaker_diarization = true;
        options.max_speaker_count = 8;
        if (!context.phrases.empty()) options.speech_contexts.push_back(context);
        // Validate before clearing the previous session, so malformed context
        // leaves the caller's previous transcript available for saving.
        engine->clear_session();
        engine->stream = engine->recognizer->streaming_recognize(options, "ko-KR");
        engine->stream->set_interim_words(true);
        engine->context_phrase_count = context.phrases.size();
        engine->context_token_count = total_tokens;
        engine->context_boost = context.phrases.empty() ? 0 : boost;
    });
}

extern "C" int32_t hn_engine_push(HNEngine *engine, const float *samples, size_t count) {
    return guarded(engine, [&] {
        if (!engine->stream || engine->finished) throw std::logic_error("start an active session before push");
        if (count > 1600 || (count && !samples)) throw std::invalid_argument("push requires 0..1600 mono 16 kHz samples");
        for (size_t i = 0; i < count; ++i)
            if (!std::isfinite(samples[i])) throw std::invalid_argument("PCM samples must be finite");
        if (!count) return;
        engine->stream->push(samples, count, 16000);
        engine->samples += count;
        engine->drain();
        ++engine->revision;
    });
}

extern "C" int32_t hn_engine_finish(HNEngine *engine) {
    return guarded(engine, [&] {
        if (engine->finished) return;
        if (!engine->stream) throw std::logic_error("start a session before finish");
        engine->accept(engine->stream->finish());
        engine->finished = true;
        engine->refresh();
        ++engine->revision;
    });
}

extern "C" int32_t hn_engine_reset(HNEngine *engine) {
    return guarded(engine, [&] { engine->clear_session(); });
}

extern "C" const char *hn_engine_snapshot_json(HNEngine *engine) {
    return guarded(engine, [&] { engine->make_json(); }) == HN_OK ? engine->json.c_str() : nullptr;
}

extern "C" const char *hn_engine_last_error(const HNEngine *engine) {
    return engine ? engine->error.c_str() : creation_error.c_str();
}

extern "C" void hn_engine_destroy(HNEngine *engine) { delete engine; }
