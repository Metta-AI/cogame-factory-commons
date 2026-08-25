# Build Docker. Paintbot's two-stage nimby build (nimby 0.1.27, Nim 2.2.4),
# producing BOTH binaries into one image: /bin/factory-commons (the game) and
# /bin/factory-commons-player (the thin prompt-carrying player). One image,
# env-switched — `PLAYER_PROMPT` for an LLM policy, `PLAYER_SCRIPTED` for a
# baseline — is the pin, not a convenience.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.27/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.27/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/factory_commons
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c $NimFlags \
    --nimcache:/tmp/factory-commons-nimcache \
    --out:factory-commons \
    src/factory_commons.nim && \
  nim c $NimFlags \
    --nimcache:/tmp/factory-commons-player-nimcache \
    --out:factory-commons-player \
    src/factory_commons_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/factory_commons
COPY --from=build /workspace/factory_commons/factory-commons \
  /bin/factory-commons
COPY --from=build /workspace/factory_commons/factory-commons-player \
  /bin/factory-commons-player
COPY --from=build /workspace/factory_commons/*.json ./
# The board art is `staticRead` into both binaries (so the wasm bundle needs no
# filesystem at all), but the PNGs ship anyway: they are the documented,
# regenerable source of the sprites.
COPY --from=build /workspace/factory_commons/data ./data

CMD ["/bin/factory-commons"]
