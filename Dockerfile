FROM golang:1.16-alpine AS builder

ARG VERSION

ENV AWS_CLI_VERSION 2.2.28
ENV MONGODB_TOOLS_VERSION 100.5.0

RUN apk add --no-cache \
    build-base \
    cmake \
    make \
    gcc \
    git \
    libc-dev \
    musl-dev \
    zlib-dev \
    libffi-dev \
    krb5-dev \
    openssl-dev \
    python3 \
    python3-dev \
    py3-pip && \
    ln -sf python3 /usr/bin/python && \
    pip install --no-cache-dir --upgrade pip wheel pycrypto

# Build mgob
COPY . /go/src/github.com/nikita/mgob
RUN cd /go/src/github.com/nikita/mgob && \
  CGO_ENABLED=0 GOOS=linux \
  go build \
  -ldflags "-X main.version=$VERSION" \
  -a -installsuffix cgo \
  -o mgob github.com/nikita/mgob/cmd/mgob

# Build mongo-tools
RUN git clone --depth 1 --single-branch --branch ${MONGODB_TOOLS_VERSION} https://github.com/mongodb/mongo-tools.git && \
  cd mongo-tools && \
  ./make build

# Move out of go dir
WORKDIR /

# Build aws-cli
RUN git clone --recursive --depth 1 --branch ${AWS_CLI_VERSION} --single-branch https://github.com/aws/aws-cli.git

WORKDIR /aws-cli

# Install PyInstaller + botocore (https://github.com/six8/pyinstaller-alpine)
RUN git clone --depth 1 --single-branch --branch v$(grep PyInstaller requirements-build.txt | cut -d'=' -f3) https://github.com/pyinstaller/pyinstaller.git /tmp/pyinstaller \
    && cd /tmp/pyinstaller/bootloader \
    && CFLAGS="-Wno-stringop-overflow -Wno-stringop-truncation" python3 ./waf configure --no-lsb all \
    && pip install .. \
    && rm -Rf /tmp/pyinstaller \
    && cd - \
    && boto_ver=$(grep botocore setup.cfg | cut -d'=' -f3) \
    && git clone --single-branch --branch v2 https://github.com/boto/botocore /tmp/botocore \
    && cd /tmp/botocore \
    && git checkout $(git log --grep $boto_ver --pretty=format:"%h") \
    && pip install . \
    && rm -Rf /tmp/botocore

RUN sed -i '/botocore/d' requirements.txt \
  && scripts/installers/make-exe

RUN unzip dist/awscli-exe.zip && \
    ./aws/install --bin-dir /aws-cli-bin && \
    rm -Rf /usr/local/aws-cli/v2/*/dist/aws_completer \
    /usr/local/aws-cli/v2/*/dist/awscli/data/ac.index \
    /usr/local/aws-cli/v2/*/dist/awscli/examples

# ========================================================================================================================
FROM alpine:3.14

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

ENV GNUPG_VERSION 2.2.27-r0
ENV AZURE_CLI_VERSION 2.27.1
ENV GOOGLE_CLOUD_SDK_VERSION 352.0.0
# Issues with s3 region in non EC2 instance with this on
ENV AWS_EC2_METADATA_DISABLED true
ENV PATH /google-cloud-sdk/bin:$PATH

LABEL org.label-schema.build-date=$BUILD_DATE \
      org.label-schema.name="mgob" \
      org.label-schema.description="MongoDB backup automation tool" \
      org.label-schema.url="https://github.com/nikita/mgob" \
      org.label-schema.vcs-ref=$VCS_REF \
      org.label-schema.vcs-url="https://github.com/nikita/mgob" \
      org.label-schema.vendor="nikita" \
      org.label-schema.version=$VERSION \
      org.label-schema.schema-version="1.0"

# Install python & PGP
RUN apk add --no-cache python3 py3-pip krb5 tzdata gnupg=${GNUPG_VERSION}

# Install azure-cli
RUN apk add --virtual=build --no-cache gcc make openssl-dev libffi-dev musl-dev linux-headers python3-dev && \
  pip install --no-cache-dir --upgrade pip wheel && \
  pip install --no-cache-dir azure-cli==${AZURE_CLI_VERSION} && \
  apk del --purge build

# Install MinIO
ADD https://dl.minio.io/client/mc/release/linux-amd64/mc /usr/bin
RUN chmod u+x /usr/bin/mc

# Install Rclone
ADD https://downloads.rclone.org/rclone-current-linux-amd64.zip /tmp
RUN cd /tmp \
  && unzip rclone-current-linux-amd64.zip \
  && cp rclone-*-linux-amd64/rclone /usr/bin/ \
  && chmod u+x /usr/bin/rclone

# Install google-cloud-sdk into /google-cloud-sdk
# https://github.com/GoogleCloudPlatform/cloud-sdk-docker/blob/6dc15d4ca5a664dcffb807a5f6ac85188258bd2d/alpine/Dockerfile
RUN wget https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${GOOGLE_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz && \
  tar xzf google-cloud-sdk-${GOOGLE_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz && \
  rm google-cloud-sdk-${GOOGLE_CLOUD_SDK_VERSION}-linux-x86_64.tar.gz && \
  rm -rf google-cloud-sdk/platform && \
  rm -rf google-cloud-sdk/data && \
  gcloud config set core/disable_usage_reporting true && \
  gcloud config set component_manager/disable_update_check true && \
  gcloud config set metrics/environment github_docker_image && \
  gcloud --version

WORKDIR /root/

# Copy mgob, mongo-tools, & aws-cli from builder
COPY --from=builder /go/src/github.com/nikita/mgob/mgob .
COPY --from=builder /go/mongo-tools/bin/* /usr/bin/
COPY --from=builder /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=builder /aws-cli-bin/ /usr/local/bin/

VOLUME ["/config", "/storage", "/tmp", "/data"]

ENTRYPOINT [ "./mgob" ]
