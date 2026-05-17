#!
-v
sudo systemctl stop ollama
sudo OLLAMA_MODELS=/usr/share/ollama/.ollama/models OLLAMA_DEBUG=2 ollama serve
