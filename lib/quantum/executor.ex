defmodule Quantum.Executor do
  @moduledoc """
  Task to actually execute a Task

  """

  use Task

  require Logger

  alias Quantum.{Job, TaskRegistry}
  alias Quantum.RunStrategy.NodeList

  @doc """
  Start the Task

  ### Arguments

    * `task_supervisor` - The supervisor that runs the task
    * `task_registry` - The registry that knows if a task is already running
    * `message` - The Message to Execute (`{:execute, %Job{}}`)

  """
  @spec start_link({GenServer.server, GenServer.server}, {:execute, Job.t}) :: {:ok, pid}
  def start_link({task_supervisor, task_registry}, {:execute, job}) do
    Task.start_link(fn ->
      execute(task_supervisor, task_registry, job)
    end)
  end

  @spec execute(GenServer.server, GenServer.server, Job.t) :: :ok
  # Execute task on all given nodes without checking for overlap
  defp execute(task_supervisor, _task_registry, %Job{overlap: true} = job) do
    job.run_strategy
    # Find Nodes to run on
    |> NodeList.nodes(job)
    # Check if Node is up and running
    |> Enum.filter(&check_node(&1, task_supervisor, job))
    # Run Task
    |> Enum.each(&run(&1, job, task_supervisor))

    :ok
  end
    # Execute task on all given nodes with checking for overlap
  defp execute(task_supervisor, task_registry, %Job{overlap: false} = job) do
    job.run_strategy
    # Find Nodes to run on
    |> NodeList.nodes(job)
    # Mark Running and only continue with item if it worked
    |> Enum.filter(&(TaskRegistry.mark_running(task_registry, job.name, &1) == :marked_running))
    # Check if Node is up and running
    |> Enum.filter(&check_node(&1, task_supervisor, job))
    # Run Task
    |> Enum.map(&run(&1, job, task_supervisor))
    # Mark Task as finished
    |> Enum.each(fn {node, %Task{ref: ref}} ->
      receive do
        {^ref, _} ->
          TaskRegistry.mark_finished(task_registry, job.name, node)
        {:DOWN, ^ref, _, _, _} ->
          TaskRegistry.mark_finished(task_registry, job.name, node)
      end
    end)

    :ok
  end

  # Ececute the given function on a given node via tge task supervisor
  @spec run(Node.t, Job.t, GenServer.server) :: {Node.t, Task.t}
  defp run(node, job, task_supervisor) do
    {node, Task.Supervisor.async_nolink({task_supervisor, node}, fn ->
      execute_task(job.task)
    end)}
  end

  @spec check_node(Node.t, GenServer.server, Job.t) :: boolean
  defp check_node(node, task_supervisor, job) do
    if running_node?(node, task_supervisor) do
      true
    else
      Logger.warn "Node #{inspect node} is not running. Job #{inspect job.name} could not be executed."
      false
    end
  end

  # Check if the task supervisor runs on a given node
  @spec running_node?(Node.t, GenServer.server) :: boolean
  defp running_node?(node, _) when node == node(), do: true
  defp running_node?(node, task_supervisor) do
    node
    |> :rpc.call(:erlang, :whereis, [task_supervisor])
    |> is_pid()
  end

  # Run function
  @spec execute_task(Quantum.Job.task) :: :ok
  defp execute_task({mod, fun, args}) do
    :erlang.apply(mod, fun, args)
    :ok
  end
  defp execute_task(fun) when is_function(fun, 0) do
    fun.()
    :ok
  end
end
