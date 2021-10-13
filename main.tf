provider "aws" {
    region = "us-east-2"
}

variable "server_port" {
    description = "The port the server will use for HTTP requests"
    type        = number
    default     = 8080
}

/*

output "<ANY-NAME>" {
value = <VALUE> must be a reference
[CONFIG ...]
}
examole is the instance name
*/


output "alb_dns_name" {
    value = aws_lb.example.dns_name
    description = "The domain name of the load balancer"
}

//to create autoscaling group, u need to create a lunch configuration first
resource "aws_launch_configuration" "example" {
    image_id = "ami-0c55b159cbfafe1f0"
    instance_type = "t2.micro"
    security_groups = [aws_security_group.instance.id]
    user_data = <<-EOF
    #!/bin/bash
    echo "Hello, World" > index.html
    nohup busybox httpd -f -p ${var.server_port} &
    EOF

    //because launch configuration is immutable, create "create_before_destroy" lifecycle setting
    //this means that terraform creates a the replacement resource first before deleting the old resource
    # Required when using a launch configuration with an auto scaling group.
    # https://www.terraform.io/docs/providers/aws/r/launch_configuration.html
    lifecycle {
        create_before_destroy = true
    }
}

//Finally, you can pull the subnet IDs out of the aws_subnet_ids data source
//and tell your ASG to use those subnets via the "vpc_zone_identifier" argument

resource "aws_autoscaling_group" "example" {
    launch_configuration = aws_launch_configuration.example.name
    vpc_zone_identifier = data.aws_subnet_ids.default.ids
    target_group_arns = [aws_lb_target_group.asg.arn]
    health_check_type = "ELB"
    min_size = 2
    max_size = 10
    tag {
        key = "Name"
        value = "terraform-asg-example"
        propagate_at_launch = true
    }
}

resource "aws_security_group" "instance" {
    name = "terraform-example-instance"
    ingress {
        from_port = var.server_port
        to_port = var.server_port
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
}


//data sources is used to specify how to  deploy your Instances across multiple subnets
//Note that with data sources, the arguments you pass in are typically search filter
//that indicate to the data source what information you’re looking for
//the code direct terraform to used the diffult vpc
/*

data "<PROVIDER>_<TYPE>" "<NAME>" {
[CONFIG ...]

}
*/
data "aws_vpc" "default" {
    default = true
}

//to reference a data in the data source use "data.<PROVIDER>_<TYPE>.<NAME>.<ATTRIBUTE>"
//then use the referenced data to lookup the subnets within the default vpc
data "aws_subnet_ids" "default" {
    vpc_id = data.aws_vpc.default.id
}

//The servers in the autoscaling group now has different IPs
//which will be difficult for users to access cause they have different IP, therefore we use a load balancer
//The load balancer distribute the traffic across the servers 
//The loadbalancer IP OR DNS link (URL) is now used to access the application
//Note that the subnets parameter configures the load balancer to use all the 
//subnets in your Default VPC by using the aws_subnet_ids data source
//use an ALB bcos it is best suited for load balancing of HTTP and HTTPS traffic
//configure the "aws_lb" resource to use this security group via the security_groups argument:
resource "aws_lb" "example" {
    name = "terraform-asg-example"
    load_balancer_type = "application"
    subnets = data.aws_subnet_ids.default.ids
    security_groups = [aws_security_group.alb.id]
}

//The EC2 listens at port 8080 while the loadbalancer listen at port 80
//define a listener for this ALB using the "aws_lb_listener resource"
resource "aws_lb_listener" "http" {
    load_balancer_arn = aws_lb.example.arn
    port = 80
    protocol = "HTTP"
    # By default, return a simple 404 page
    default_action {
    type = "fixed-response"
    fixed_response {
    content_type = "text/plain"
    message_body = "404: page not found"
    status_code = 404
    }
    }
}

//Create a target group for your ASG using the aws_lb_target_group resource
//The target group periodically sending an HTTP request to each Instance to check for a 200 OK response and make the server "Healthy"
resource "aws_lb_target_group" "asg" {
    name = "terraform-asg-example"
    port = var.server_port
    protocol = "HTTP"
    vpc_id = data.aws_vpc.default.id
    health_check {
        path = "/"
        protocol = "HTTP"
        matcher = "200"
        interval = 15
        timeout = 3
        healthy_threshold = 2
        unhealthy_threshold = 2
    }
}

//For the target group know which EC2 Instances to send requests to the ALB, you should
//attach EC2 Instances to the target group using the "aws_lb_target_group_attachment" resource

//creating a listener rules using the aws_lb_listener_rule resource
//This code adds a listener rule that send requests that match any path to the target group that contains your ASG
resource "aws_lb_listener_rule" "asg" {
    listener_arn = aws_lb_listener.http.arn
    priority = 100
    condition {
        path_pattern {
        values = ["*"]
        }
    }
action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
}
}

//For the loadbalancer to actually listen at port 80
//we need to the configures a new security group to allow incoming traffic at the port 80 and outgoing traffic at port 0

resource "aws_security_group" "alb" {
    name = "terraform-example-alb"
    # Allow inbound HTTP requests
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    # Allow all outbound requests
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}





