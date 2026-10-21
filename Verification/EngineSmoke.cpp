// Bounded contract smoke. Link against the same pinned runtime as the app.
#include "HwajaEngine.h"
#include "wav_reader.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

using json = nlohmann::json;
void require(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void check(HNEngine *engine, int status) {
    if (status) throw std::runtime_error(hn_engine_last_error(engine));
}
json snapshot(HNEngine *engine) {
    const char *text = hn_engine_snapshot_json(engine);
    if (!text) throw std::runtime_error(hn_engine_last_error(engine));
    return json::parse(text);
}

int main(int argc, char **argv) {
    if (argc < 5 || argc > 8) { std::cerr << "EngineSmoke ASR.gguf DIAR.gguf INPUT.wav OUTPUT.json [--endpoints] [--right13] [--official]\n"; return 2; }
    int right_context = 3, diar_profile = 1;
    bool endpoints = false;
    for (int i = 5; i < argc; ++i) {
        const std::string option = argv[i];
        if (option == "--endpoints") endpoints = true;
        else if (option == "--right13") right_context = 13;
        else if (option == "--official") diar_profile = 0;
        else { std::cerr << "Unknown option: " << option << '\n'; return 2; }
    }
    HNEngine *engine = nullptr;
    try {
        require(hn_engine_create(nullptr, nullptr, 3) == nullptr, "null paths accepted");
        require(std::string(hn_engine_last_error(nullptr)).find("HN_INVALID_ARGUMENT") == 0,
                "create error prefix missing");
        engine = hn_engine_create_configured(argv[1], argv[2], right_context, diar_profile);
        require(engine != nullptr, hn_engine_last_error(nullptr));
        std::vector<float> audio;
        std::string error;
        require(examples::read_wav_mono_16k(argv[3], audio, error), error.c_str());
        check(engine, hn_engine_start(engine));
        require(hn_engine_push(engine, audio.data(), 1601) == HN_INVALID_ARGUMENT,
                "oversized input accepted");
        float invalid = std::numeric_limits<float>::quiet_NaN();
        require(hn_engine_push(engine, &invalid, 1) == HN_INVALID_ARGUMENT, "NaN accepted");
        require(snapshot(engine)["audio_seconds"] == 0, "invalid input changed audio clock");
        size_t interim_words = 0, tagged_interims = 0, words_at_last_update = 0;
        double first_text_audio = -1, first_tag_audio = -1;
        for (size_t offset = 0; offset < audio.size(); offset += 1600) {
            const size_t count = std::min(size_t(1600), audio.size() - offset);
            check(engine, hn_engine_push(engine, audio.data() + offset, count));
            const auto value = snapshot(engine);
            require(value["is_final"] == false, "interim session marked final");
            require(value["language"] == "ko-KR", "Korean prompt metadata missing");
            if (!value["text"].get<std::string>().empty() && first_text_audio < 0)
                first_text_audio = value["audio_seconds"];
            if (!value["words"].empty()) {
                ++interim_words;
                words_at_last_update = value["words"].size();
            }
            bool tagged = false;
            for (const auto &word : value["words"]) {
                require(word["speaker"].get<int>() >= 0 && word["speaker"].get<int>() <= 8,
                        "speaker outside model capacity");
                require(word["end"].get<double>() >= word["start"].get<double>(), "negative word interval");
                tagged = tagged || word["speaker"].get<int>() > 0;
            }
            if (tagged) {
                ++tagged_interims;
                if (first_tag_audio < 0) first_tag_audio = value["audio_seconds"];
            }
        }
        check(engine, hn_engine_finish(engine));
        const auto result = snapshot(engine);
        require(result["engine_version"] == "0.2.0", "wrong runtime version");
        if (endpoints) require(result["finalized_utterances"].get<int>() >= 2, "utterance boundary was not exercised");
        require(result["is_final"] == true, "finish flag missing");
        require(!result["text"].get<std::string>().empty(), "empty final transcript");
        require(result["words"].size() >= words_at_last_update, "final dropped words");
        require(interim_words > 0 && tagged_interims > 0, "live word/speaker updates absent");
        check(engine, hn_engine_finish(engine));
        require(result == snapshot(engine), "finish should be idempotent");
        require(hn_engine_push(engine, audio.data(), 100) == HN_INVALID_STATE, "finished stream accepted audio");
        const char *bad_phrase = "$NAME";
        require(hn_engine_start_with_context(engine, &bad_phrase, 1, 1.0f) == HN_INVALID_ARGUMENT,
                "unsupported class context accepted");
        require(result == snapshot(engine), "invalid context destroyed finished transcript");
        check(engine, hn_engine_start(engine));
        const auto fresh = snapshot(engine);
        require(fresh["text"] == "" && fresh["words"].empty() && fresh["audio_seconds"] == 0,
                "fresh session retained transcript or time");
        std::vector<float> silence(1600, 0.0f);
        check(engine, hn_engine_push(engine, silence.data(), silence.size()));
        check(engine, hn_engine_finish(engine));
        const auto silent = snapshot(engine);
        require(silent["text"] == "" && silent["is_final"] == true,
                "silent fresh session leaked transcript");
        check(engine, hn_engine_reset(engine));
        require(snapshot(engine)["state"] == "ready", "reset did not close session");
        const char *phrase = "회의 일정";
        check(engine, hn_engine_start_configured(engine, &phrase, 1, 1.0f, 0));
        require(snapshot(engine)["context_phrase_count"] == 1, "embedded tokenizer context failed");
        check(engine, hn_engine_finish(engine));
        json report = {{"passed", true}, {"interim_word_updates", interim_words},
            {"interim_tagged_updates", tagged_interims}, {"first_text_audio_seconds", first_text_audio},
            {"first_tag_audio_seconds", first_tag_audio}, {"final", result}, {"fresh_silent_session", silent}};
        std::ofstream(argv[4]) << report.dump(2) << '\n';
        hn_engine_destroy(engine);
        std::cout << "PASS interim_words=" << interim_words << " tagged_interims=" << tagged_interims
                  << " final_words=" << result["words"].size() << " fresh_session=clean\n";
        return 0;
    } catch (const std::exception &e) {
        hn_engine_destroy(engine);
        std::cerr << "FAIL " << e.what() << '\n';
        return 1;
    }
}
