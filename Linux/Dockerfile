FROM swift:6.2.1-noble
COPY scripts/linux-deps.sh /tmp/linux-deps.sh
RUN TAGX_BUILD_JOBS=4 sh /tmp/linux-deps.sh && rm /tmp/linux-deps.sh
RUN apt-get update -qq && apt-get install -y -qq libqpdf-dev imagemagick && rm -rf /var/lib/apt/lists/*
WORKDIR /src
