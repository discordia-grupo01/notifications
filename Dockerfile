FROM hexpm/elixir:1.16.2-erlang-26.2.1-alpine-3.19.1 AS builder
WORKDIR /app
RUN apk add --no-cache git && mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
COPY . .
ENV MIX_ENV=prod
RUN mix compile && mix release

FROM alpine:3.19.1
RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates tailscale socat \
 && addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/notifications ./
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh && chmod +x /usr/local/bin/docker-entrypoint.sh
USER app
ENV RELEASE_TMP=/tmp/notifications
EXPOSE 4000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["start"]
