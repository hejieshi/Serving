#!/usr/bin/env bash

function init() {
    source /root/.bashrc
    set -v
    export PYTHONROOT=/usr
    cd Serving
}

function check_cmd() {
    eval $@
    if [ $? -ne 0 ]; then
        exit 1
    fi
}

function build_client() {
    local TYPE=$1
    local DIRNAME=build-client-$TYPE
    mkdir $DIRNAME # pwd: /Serving
    cd $DIRNAME # pwd: /Serving/build-client-$TYPE
    case $TYPE in
        CPU|GPU)
            cmake -DPYTHON_INCLUDE_DIR=$PYTHONROOT/include/python2.7/ \
                  -DPYTHON_LIBRARIES=$PYTHONROOT/lib64/libpython2.7.so \
                  -DPYTHON_EXECUTABLE=$PYTHONROOT/bin/python \
                  -DCLIENT_ONLY=ON ..
            check_cmd "make -j2 >/dev/null"
            pip install -U python/dist/paddle_serving_client* >/dev/null
            ;;
        *)
            echo "error type"
            exit 1
            ;;
    esac
    echo "build client $TYPE part finished as expected."
    cd .. # pwd: /Serving
    rm -rf $DIRNAME
}

function build_server() {
    local TYPE=$1
    local DIRNAME=build-server-$TYPE
    mkdir $DIRNAME # pwd: /Serving
    cd $DIRNAME # pwd: /Serving/build-server-$TYPE
    case $TYPE in
        CPU)
            cmake -DPYTHON_INCLUDE_DIR=$PYTHONROOT/include/python2.7/ \
                  -DPYTHON_LIBRARIES=$PYTHONROOT/lib64/libpython2.7.so \
                  -DPYTHON_EXECUTABLE=$PYTHONROOT/bin/python \
                  -DCLIENT_ONLY=OFF ..
            check_cmd "make -j2 >/dev/null && make install -j2 >/dev/null"
            pip install -U python/dist/paddle_serving_server* >/dev/null
            ;;
        GPU)
            cmake -DPYTHON_INCLUDE_DIR=$PYTHONROOT/include/python2.7/ \
                  -DPYTHON_LIBRARIES=$PYTHONROOT/lib64/libpython2.7.so \
                  -DPYTHON_EXECUTABLE=$PYTHONROOT/bin/python \
                  -DCLIENT_ONLY=OFF \
                  -DWITH_GPU=ON ..
            check_cmd "make -j2 >/dev/null && make install -j2 >/dev/null"
            pip install -U python/dist/paddle_serving_server* >/dev/null
            ;;
        *)
            echo "error type"
            exit 1
            ;;
    esac
    echo "build server $TYPE part finished as expected."
    cd .. # pwd: /Serving
    # rm -rf $DIRNAME    for export SERVING_BIN
}

function kill_server_process() {
    ps -ef | grep "serving" | grep -v serving_build | grep -v grep | awk '{print $2}' | xargs kill
}

function python_test_fit_a_line() {
    # pwd: /Serving/python/examples
    cd fit_a_line # pwd: /Serving/python/examples/fit_a_line
    sh get_data.sh
    local TYPE=$1
    echo $TYPE
    case $TYPE in
        CPU)
            # test rpc
            check_cmd "python -m paddle_serving_server.serve --model uci_housing_model --port 9393 --thread 4 > /dev/null &"
            sleep 5 # wait for the server to start
            check_cmd "python test_client.py uci_housing_client/serving_client_conf.prototxt > /dev/null"
            kill_server_process
            # test web
            check_cmd "python -m paddle_serving_server.serve --model uci_housing_model --name uci --port 9393 --thread 4 --name uci > /dev/null &"
            sleep 5 # wait for the server to start
            check_cmd "curl -H \"Content-Type:application/json\" -X POST -d '{\"x\": [0.0137, -0.1136, 0.2553, -0.0692, 0.0582, -0.0727, -0.1583, -0.0584, 0.6283, 0.4919, 0.1856, 0.0795, -0.0332], \"fetch\":[\"price\"]}' http://127.0.0.1:9393/uci/prediction"
            # check http code
            http_code=`curl -H "Content-Type:application/json" -X POST -d '{"x": [0.0137, -0.1136, 0.2553, -0.0692, 0.0582, -0.0727, -0.1583, -0.0584, 0.6283, 0.4919, 0.1856, 0.0795, -0.0332], "fetch":["price"]}' -s -w "%{http_code}" -o /dev/null http://127.0.0.1:9393/uci/prediction`
            if [ ${http_code} -ne 200 ]; then
                echo "HTTP status code -ne 200"
                exit 1
            fi
            kill_server_process
            ;;
        GPU)
            # test rpc
            check_cmd "python -m paddle_serving_server_gpu.serve --model uci_housing_model --port 9393 --thread 4 --gpu_ids 0 > /dev/null &"
            sleep 5 # wait for the server to start
            check_cmd "python test_client.py uci_housing_client/serving_client_conf.prototxt > /dev/null"
            kill_server_process

            # test web
            check_cmd "python -m paddle_serving_server_gpu.serve --model uci_housing_model --port 9393 --thread 2 --gpu_ids 0 --name uci > /dev/null &"
            sleep 5 # wait for the server to start
            check_cmd "curl -H \"Content-Type:application/json\" -X POST -d '{\"x\": [0.0137, -0.1136, 0.2553, -0.0692, 0.0582, -0.0727, -0.1583, -0.0584, 0.6283, 0.4919, 0.1856, 0.0795, -0.0332], \"fetch\":[\"price\"]}' http://127.0.0.1:9393/uci/prediction"
            # check http code
            http_code=`curl -H "Content-Type:application/json" -X POST -d '{"x": [0.0137, -0.1136, 0.2553, -0.0692, 0.0582, -0.0727, -0.1583, -0.0584, 0.6283, 0.4919, 0.1856, 0.0795, -0.0332], "fetch":["price"]}' -s -w "%{http_code}" -o /dev/null http://127.0.0.1:9393/uci/prediction`
            if [ ${http_code} -ne 200 ]; then
                echo "HTTP status code -ne 200"
                exit 1
            fi
            kill_server_process
            ;;
        *)
            echo "error type"
            exit 1
            ;;
    esac
    echo "test fit_a_line $TYPE part finished as expected."
    rm -rf image kvdb log uci_housing* work*
    cd .. # pwd: /Serving/python/examples
}

function python_run_criteo_ctr_with_cube() {
    # pwd: /Serving/python/examples
    local TYPE=$1
    yum install -y bc >/dev/null
    cd criteo_ctr_with_cube # pwd: /Serving/python/examples/criteo_ctr_with_cube
    check_cmd "wget https://paddle-serving.bj.bcebos.com/unittest/ctr_cube_unittest.tar.gz"
    check_cmd "tar xf ctr_cube_unittest.tar.gz"
    check_cmd "mv models/ctr_client_conf ./"
    check_cmd "mv models/ctr_serving_model_kv ./"
    check_cmd "mv models/data ./cube/"
    check_cmd "mv models/ut_data ./"
    cp ../../../build-server-$TYPE/output/bin/cube* ./cube/ 
    mkdir -p $PYTHONROOT/lib/python2.7/site-packages/paddle_serving_server/serving-cpu-avx-openblas-0.1.3/
    yes | cp ../../../build-server-$TYPE/output/demo/serving/bin/serving $PYTHONROOT/lib/python2.7/site-packages/paddle_serving_server/serving-cpu-avx-openblas-0.1.3/

    sh cube_prepare.sh &
    check_cmd "mkdir work_dir1 && cp cube/conf/cube.conf ./work_dir1/"    
    python test_server.py ctr_serving_model_kv &
    check_cmd "python test_client.py ctr_client_conf/serving_client_conf.prototxt ./ut_data >score"
    AUC=$(tail -n 2  score | awk 'NR==1')
    VAR2="0.70"
    RES=$( echo "$AUC>$VAR2" | bc )
    if [[ $RES -eq 0 ]]; then
        echo "error with criteo_ctr_with_cube inference auc test, auc should > 0.70"
        exit 1
    fi
    echo "criteo_ctr_with_cube inference auc test success"
    ps -ef | grep "paddle_serving_server" | grep -v grep | awk '{print $2}' | xargs kill
    ps -ef | grep "cube" | grep -v grep | awk '{print $2}' | xargs kill
    cd .. # pwd: /Serving/python/examples
}

function python_run_test() {
    # Using the compiled binary
    local TYPE=$1 # pwd: /Serving
    export SERVING_BIN=$PWD/build-server-${TYPE}/core/general-server/serving
    cd python/examples # pwd: /Serving/python/examples
    python_test_fit_a_line $TYPE # pwd: /Serving/python/examples
    python_run_criteo_ctr_with_cube $TYPE # pwd: /Serving/python/examples
    echo "test python $TYPE part finished as expected."
    cd ../.. # pwd: /Serving
}

function main() {
    local TYPE=$1 # pwd: /
    init # pwd: /Serving
    build_client $TYPE # pwd: /Serving
    build_server $TYPE # pwd: /Serving
    python_run_test $TYPE # pwd: /Serving
    echo "serving $TYPE part finished as expected."
}

main $@
