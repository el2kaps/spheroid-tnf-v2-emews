import files;
import string;
import sys;
import io;
import stats;
import python;
import math;
import location;
import assert;
// import R;

import EQPy;

string emews_root = getenv("EMEWS_PROJECT_ROOT");
string turbine_output = getenv("TURBINE_OUTPUT");
string resident_work_ranks = getenv("RESIDENT_WORK_RANKS");
string r_ranks[] = split(resident_work_ranks,",");

string to_xml_code =
"""
import params2xml
import json

params = json.loads('%s')
params['user_parameters.random_seed'] = '%s'

default_settings = '%s'
xml_out = '%s'

params2xml.params_to_xml(params, default_settings, xml_out)
""";

string result_template =
"""
import statistics

x = '%s'.split(',')
x = [float(xx) for xx in x]

if len(x) > 0:
  res = statistics.mean(x)
else:
  res = 9999999999
""";

// string result_template =
// """
// x <- c(%s)

// res <- ifelse(length(x) > 0, mean(x), 9999999999)
// """;

string count_template =
"""
import get_metrics

instance_dir = '%s'

count = get_metrics.get_tumor_cell_count(instance_dir)
""";

app (file out, file err) run_model (string model_sh, string executable_path, string settings_file, string instance)
{
    "bash" model_sh executable_path settings_file emews_root instance @stdout=out @stderr=err;
}

app (void o) summarize_simulation (file summarize_py, string instance_dir) {
    "python" summarize_py instance_dir;
}

(string result) get_result(string instance_dir) {
  // Use a few lines of R code to read the output file
  // See the read_last_row variable above
  string code = count_template % instance_dir;
  result = python_persist(code, "str(count)");
}

(string result) run_obj(string custom_parameters, int sa_iteration, int parameter_iteration, int num_replications, string executable, string default_xml)
{
    file summarize_py = input(emews_root + "/scripts/summarize_simulation_DD.py");
    string cell_counts[];
    foreach replication in [0:num_replications-1:1] {
      // make instance dir
      string instance_dir = "%s/instance_%i_%i_%i/" % (turbine_output, sa_iteration, parameter_iteration, replication+1);
      make_dir(instance_dir) => {
        string xml_out = instance_dir + "settings.xml";
        // replication iteration used as a seed
        string code = to_xml_code % (custom_parameters, replication, default_xml, xml_out);
        file out <instance_dir + "out.txt">;
        file err <instance_dir + "err.txt">;
        string model_sh = emews_root + "/scripts/growth_model.sh";
        python_persist(code, "'ignore'") =>
        (out,err) = run_model(model_sh, executable, xml_out, instance_dir) => {
          cell_counts[replication] = get_result(instance_dir);
          summarize_simulation (summarize_py, instance_dir) => {
            rm_dir(instance_dir);
          }
        }
      }
    }

    string cell_counts_string = string_join(cell_counts, ",");
    string code = result_template % cell_counts_string;
    result = python_persist(code, "str(res)");

}

(void v) loop (location ME, int trials, string executable_model, string default_xml) {
    for (boolean b = true, int i = 1;
       b;
       b=c, i = i + 1)
  {
    // gets the model parameters from the python algorithm
    string params =  EQPy_get(ME);
    boolean c;
    // TODO
    // Edit the finished flag, if necessary.
    // when the python algorithm is finished it should
    // pass "DONE" into the queue, and then the
    // final set of parameters. If your python algorithm
    // passes something else then change "DONE" to that
    if (params == "DONE")
    {
        string finals =  EQPy_get(ME);
        // TODO if appropriate
        // split finals string and join with "\\n"
        // e.g. finals is a ";" separated string and we want each
        // element on its own line:
        // multi_line_finals = join(split(finals, ";"), "\\n");
        string fname = "%s/final_result" % (turbine_output);
        file results_file <fname> = write(finals) =>
        printf("Writing final result to %s", fname) =>
        // printf("Results: %s", finals) =>
        v = make_void() =>
        c = false;
    }
    else if (params == "EQPY_ABORT")
    {
        printf("EQPy Aborted");
        string why = EQPy_get(ME);
        // TODO handle the abort if necessary
        // e.g. write intermediate results ...
        printf("%s", why) =>
        v = propagate() =>
        c = false;
    }
    else
    {
        string param_array[] = split(params, ";");
        string results[];
        foreach parameter, parameter_iteration in param_array
        {
            results[parameter_iteration] = run_obj(parameter, i, parameter_iteration, trials, executable_model, default_xml);
        }

        string result = join(results, ";");
        //printf("passing %s", res);
        EQPy_put(ME, result) => c = true;
    }
  }
}

// TODO
// Edit function arguments to include those passed from main function
// below
(void o) start (int ME_rank, int num_iterations, int num_population, int num_variations, int random_seed, string sa_parameters_file, string executable_model, string default_xml) {
    location ME = locationFromRank(ME_rank);
    // TODO: Edit algo_params to include those required by the python
    // algorithm.
    // algo_params are the parameters used to initialize the
    // python algorithm. We pass these as a comma separated string.
    // By default we are passing a random seed. String parameters
    // should be passed with a \"%s\" format string.
    // e.g. algo_params = "%d,%\"%s\"" % (random_seed, "ABC");
    string algo_params = "%d,%d,%d,'%s'" %  (num_iterations, num_population, random_seed, sa_parameters_file);
    EQPy_init_package(ME,"sa") =>
    EQPy_get(ME) =>
    EQPy_put(ME, algo_params) =>
      loop(ME, num_variations, executable_model, default_xml) => {
        EQPy_stop(ME);
        o = propagate();
    }
}

// deletes the specified directory
app (void o) rm_dir(string dirname) {
  "rm" "-rf" dirname;
}

// call this to create any required directories
app (void o) make_dir(string dirname) {
  "mkdir" "-p" dirname;
}

main() {

  // TODO
  // Retrieve arguments to this script here
  // these are typically used for initializing the python algorithm
  // Here, as an example, we retrieve the number of variations (i.e. trials)
  // for each model run, and the random seed for the python algorithm.
  string executable = argv("exe");
  string default_xml = argv("settings");

  int random_seed = toint(argv("seed", "0"));
  int num_variations = toint(argv("nv", "3"));
  int num_iterations = toint(argv("ni","10"));
  int num_population = toint(argv("np", "5"));
  string sa_parameters_file = argv("sa_parameters");

  // PYTHONPATH needs to be set for python code to be run
  assert(strlen(getenv("PYTHONPATH")) > 0, "Set PYTHONPATH!");
  assert(strlen(emews_root) > 0, "Set EMEWS_PROJECT_ROOT!");

  int rank = string2int(r_ranks[0]);
  start(rank, num_iterations, num_population, num_variations, random_seed, sa_parameters_file, executable, default_xml);
}
