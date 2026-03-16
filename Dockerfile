# Beacon Framework — Production Dockerfile
# Multi-stage build: compile on Gleam image, run on minimal Erlang image

# Stage 1: Build
FROM ghcr.io/gleam-lang/gleam:v1.6.3-erlang-alpine AS builder

WORKDIR /app
COPY gleam.toml manifest.toml ./
COPY src/ src/
COPY test/ test/
COPY priv/ priv/
COPY beacon_client/ beacon_client/

RUN gleam build
RUN gleam run -m beacon/build || true

# Stage 2: Run
FROM erlang:27-alpine

WORKDIR /app

# Copy compiled BEAM files
COPY --from=builder /app/build/dev/erlang/ ./build/dev/erlang/
COPY --from=builder /app/priv/ ./priv/
COPY --from=builder /app/gleam.toml ./

# Set production defaults
ENV BEACON_ENV=production
ENV PORT=8080

EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD wget -q --spider http://localhost:8080/health || exit 1

# Start the application
CMD ["erl", "-pa", "build/dev/erlang/*/ebin", "-noshell", "-eval", "application:ensure_all_started(beacon)"]
