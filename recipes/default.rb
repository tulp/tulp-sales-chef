class Chef::Recipe
  include Express42::Base::Network
end

include_recipe('iptables')
include_recipe('nginx')
include_recipe('rvm')
include_recipe('runit')
include_recipe('tulp')

if Chef::Config[:solo]
  Chef::Log.warn("This recipe uses search. Chef Solo does not support search. I will return current node")
  postgresql_master_node = node
else
  postgresql_master_node = search(:node, "role:postgresql-master AND chef_environment:#{node.chef_environment}")[0]
end

raise "Postgresql master role not found, application can't work w/o postgresql" if not postgresql_master_node

postgresql_master_server = net_get_private_ip(postgresql_master_node)

iptables_rule "internal"
iptables_rule 'http'

app_name = 'tulp-sales'
environment = node[app_name]["environment"]
user = node[app_name]["application_user"]
app_dir = node[app_name]["application_directory"] 

directory app_dir do
  owner user
  group user
end

directory "#{app_dir}/shared" do
  owner user
  group user
end

directory "#{app_dir}/shared/config" do
  owner user
  group user
end

link "/home/#{user}/#{app_name}" do
  to app_dir
end

pg_pass = data_bag_item('psql_tulp_master', 'users')['users']['tulp']['options']['password']

template "#{app_dir}/shared/config/database.yml" do
  cookbook 'tulp'
  source 'database.yml.erb'
  owner user
  group user
  variables :db_name => node["tulp-sales"]["application"]["database_name"],
            :password => pg_pass,
            :host => postgresql_master_server,
            :environment => environment
end

sudo "tulp" do
  user user
  commands ["/usr/bin/sv * tulp*"]
  host "ALL"
  nopasswd true
end

rvm_ruby "ruby-2.1.0" do
  user user
end
  
rvm_default_ruby "ruby-2.1.0" do
  user user
end

rvm_gem 'bundler' do
  version '1.5.1'
  action :upgrade
  user user
end

template "/etc/logrotate.d/tulp-sales-application" do
  owner "root"
  group "root"
  mode 0644
  source "application-logrotate.erb"
  variables(
    :logs => "#{app_dir}/shared/log",
    :pidfile => "#{app_dir}/current/tmp/pids/unicorn.pid",
    :rotate => 90
  )
end

runit_service "tulp_rails" do
  default_logger true
  cookbook 'tulp'
  run_template_name "rails_app"
  options({
    :home_path => "/home/#{user}",
    :app_path => "#{app_dir}",
    :target_user => user,
    :target_ruby => "default",
    :target_env => environment
  })
end

template "#{app_dir}/shared/config/unicorn.rb" do
  source 'unicorn.rb.erb'
  owner user
  group user
  variables :app_path => app_dir,
            :worker_processes => 1,
            :listen => "/tmp/tulp-rails.sock",
            :environment => environment
end

template "#{app_dir}/shared/config/secrets.yml" do
  source 'secrets.yml.erb'
  owner user
  group user
  variables secrets: node[app_name]['secrets']
end

address = net_get_private_ip(node)
template "#{node['nginx']['dir']}/sites-available/nginx-application-tulp.conf" do
    cookbook 'tulp'
    source "nginx-application-tulp.erb"
    mode "0644"
    variables :app_path => app_dir,
              :backend => "unix:/tmp/tulp-rails.sock",
              :address => "#{address}",
              :protected_site => node["tulp"]["application"]["protected_site"],
              :frontend_servers_ip => [],
              :app_serves_static_assets => (environment == "development") ? true : false,
              :proxy_user_static_to_production => node["tulp"]["application"]["proxy_user_static_to_production"],
              :intercept_errors => (environment == "development") ? false : true
    notifies :reload, resources(:service => "nginx")
end

nginx_site "nginx-application-tulp.conf"

# dependency for 'pq' gem
package 'libpq-dev'


# install nodejs to work with assets
package 'nodejs'
package 'nodejs-legacy'

execute "Install npm" do
  command "curl https://www.npmjs.org/install.sh | bash"
  not_if 'which npm'
  action :run
end

