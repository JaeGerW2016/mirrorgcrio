#!/bin/bash

GCR_NAMESPACE=gcr.io/google-containers
DOCKERHUB_NAMESPACE=mirrorgcrio

today(){
   date +%F
}

git_init(){
    git config --global user.name "jasper"
    git config --global user.email 314315960@qq.com
    git remote rm origin
    git remote add origin git@github.com:JaeGerW2016/mirrorgcrio.git
    git pull
    if git branch -a |grep 'origin/develop' &> /dev/null ;then
        git checkout develop
        git pull origin develop
        git branch --set-upstream-to=origin/develop develop
    else
        git checkout -b develop
        git pull origin develop
    fi
}

git_commit(){
     local COMMIT_FILES_COUNT=$(git status -s|wc -l)
     local TODAY=$(today)
     if [ $COMMIT_FILES_COUNT -ne 0 ];then
        git add -A
        git commit -m "Synchronizing completion at $TODAY"
        git push -u origin develop
     fi
}

add_yum_repo() {
cat > /etc/yum.repos.d/google-cloud-sdk.repo <<EOF
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
}

add_apt_source(){
export CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)"
echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
}

install_sdk() {
    local OS_VERSION=$(grep -Po '(?<=^ID=")\w+' /etc/os-release)
    local OS_VERSION=${OS_VERSION:-ubuntu}
    if [[ $OS_VERSION =~ "centos" ]];then
        if ! [ -f /etc/yum.repos.d/google-cloud-sdk.repo ];then
            add_yum_repo
            yum -y install google-cloud-sdk
        else
            echo "gcloud is installed"
        fi
    elif [[ $OS_VERSION =~ "ubuntu" ]];then
        if ! [ -f /etc/apt/sources.list.d/google-cloud-sdk.list ];then
            add_apt_source
            sudo apt-get -y update && sudo apt-get -y install google-cloud-sdk
        else
             echo "gcloud is installed"
        fi
    fi
}

auth_sdk(){
    local AUTH_COUNT=$(gcloud auth list --format="get(account)"|wc -l)
    if [ $AUTH_COUNT -eq 0 ];then
        gcloud auth activate-service-account --key-file=$HOME/gcloud.config.json
    else
        echo "gcloud service account is exsits"
    fi
}

repository_list() {
    if ! [ -f repo_list.txt ];then
        gcloud container images list --repository=${GCR_NAMESPACE} --format="value(NAME)" > repo_list.txt && \
        echo "get repository list done"
    else
        /bin/mv  -f repo_list.txt old_repo_list.txt
        gcloud container images list --repository=${GCR_NAMESPACE} --format="value(NAME)" > repo_list.txt && \
        echo "get repository list done"
        DEL_REPO=($(diff  -B -c  old_repo_list.txt repo_list.txt |grep -Po '(?<=^\- ).+|xargs')) && \
        rm -f old_repo_list.txt
        if [ ${#DEL_REPO} -ne 0 ];then
            for i in ${DEL_REPO[@]};do
                rm -rf ${i##*/}
            done
        fi
    fi
}

generate_changelog(){
    if  ! [ -f CHANGELOG.md ];then
        echo  >> CHANGELOG.md
    fi

}

push_image(){
    GCR_IMAGE=$1
    DOCKERHUB_IMAGE=$2
    docker pull ${GCR_IMAGE}
    docker tag ${GCR_IMAGE} ${DOCKERHUB_IMAGE}
    docker push ${DOCKERHUB_IMAGE}
    echo "$IMAGE_TAG_SHA" > ${IMAGE_NAME}/${i}
    sed -i  "1i\- ${DOCKERHUB_IMAGE}"  CHANGELOG.md
}

clean_images(){
     IMAGES_COUNT=$(docker image ls|wc -l)
     if [ $IMAGES_COUNT -gt 1 ];then
         docker image prune -a -f
     fi
}

clean_disk(){
    DODCKER_ROOT_DIR=$(docker info --format '{{json .}}'|jq  -r '.DockerRootDir')
    USAGE=$(df $DODCKER_ROOT_DIR|awk -F '[ %]+' 'NR>1{print $5}')
    if [ $USAGE -eq 80 ];then
        wait
        clean_images
    fi
}

main() {
    git_init
    install_sdk
    auth_sdk
    repository_list
    generate_changelog
    TODAY=$(today)
    PROGRESS_COUNT=0
    LINE_NUM=0
    LAST_REPOSITORY=$(tail -n 1 repo_list.txt)
    while read GCR_IMAGE_NAME;do
        let LINE_NUM++
        IMAGE_INFO_JSON=$(gcloud container images list-tags $GCR_IMAGE_NAME  --filter="tags:*" --format=json)
        TAG_INFO_JSON=$(echo "$IMAGE_INFO_JSON"|jq '.[]|{ tag: .tags[] ,digest: .digest }')
        TAG_LIST=($(echo "$TAG_INFO_JSON"|jq -r .tag))
        IMAGE_NAME=${GCR_IMAGE_NAME##*/}
        if [ -f  breakpoint.txt ];then
           SAVE_DAY=$(head -n 1 breakpoint.txt)
           if [[ $SAVE_DAY != $TODAY ]];then
             :> breakpoint.txt
           else
               BREAK_LINE=$(tail -n 1 breakpoint.txt)
               if [ $LINE_NUM -lt $BREAK_LINE ];then
                   continue
               fi
           fi
        fi
        for i in ${TAG_LIST[@]};do
            GCR_IMAGE=${GCR_IMAGE_NAME}:${i}
            DOCKERHUB_IMAGE=${DOCKERHUB_NAMESPACE}/${IMAGE_NAME}:${i}
            IMAGE_TAG_SHA=$(echo "${TAG_INFO_JSON}"|jq -r "select(.tag == \"$i\")|.digest")
            if [[ $GCR_IMAGE_NAME == $LAST_REPOSITORY ]];then
                LAST_TAG=${TAG_LIST[-1]}
                LAST_IMAGE=${LAST_REPOSITORY}:${LAST_TAG}
                if [[ $GCR_IMAGE  == $LAST_IMAGE ]];then
                    wait
                    clean_images
                fi
            fi
            if [ -f $IMAGE_NAME/$i ];then
                echo "$IMAGE_TAG_SHA"  > /tmp/diff.txt
                if ! diff /tmp/diff.txt $IMAGE_NAME/$i &> /dev/null ;then
                     clean_disk
                     push_image $GCR_IMAGE $DOCKERHUB_IMAGE &
                     let PROGRESS_COUNT++
                fi
            else
                mkdir -p $IMAGE_NAME
                clean_disk
                push_image $GCR_IMAGE $DOCKERHUB_IMAGE &
                let PROGRESS_COUNT++
            fi
            COUNT_WAIT=$[$PROGRESS_COUNT%50]
            if [ $COUNT_WAIT -eq 0 ];then
               wait
               clean_images
               git_commit
            fi
        done
        if [ $COUNT_WAIT -eq 0 ];then
            wait
            clean_images
            git_commit
        fi

        echo "sync image $MY_REPO/$IMAGE_NAME done."
        echo -e "$TODAY\n$LINE_NUM" > breakpoint.txt
    done < repo_list.txt 
    sed -i "1i-------------------------------at $(date +'%F %T') sync image repositorys-------------------------------"  CHANGELOG.md
    git_commit
}

main
