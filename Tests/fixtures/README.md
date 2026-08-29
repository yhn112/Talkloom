# ASR smoke fixtures

The committed `.txt` files are the reference transcripts. Their paired `.wav` files are
private/generated artifacts and stay ignored by git. Generate them with
`scripts/generate-asr-smoke-fixtures.sh`, then run the live OpenRouter baseline with
`scripts/openrouter-asr-eval.sh` after writing the key as the only line of the ignored
repository-root file `.openrouter.apikey`. Direct invocations of the evaluation executable
may still use `OPENROUTER_API_KEY` as an ephemeral override.

These voices are synthetic. They detect broken request, language, silence and timing
behavior, but they are not evidence that a model is good enough for real meetings. Model
selection still needs real Russian and English excerpts with noise and interruptions.

The evaluation executable is not linked into Talkloom.app. The runner refuses to proceed
with a missing or committable key file but never reads it; the evaluator alone reads the fixed
file. This does not weaken the app's eventual Keychain-only credential rule.
